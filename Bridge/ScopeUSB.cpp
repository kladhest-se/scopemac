// SPDX-License-Identifier: GPL-3.0-or-later
// USBTMC behavior follows the tested OpenHantek DSO2D15 experimental backend.
#include "ScopeUSB.h"
#include <libusb.h>
#include <vector>
#include <algorithm>
#include <memory>
#include <string>
#include <stdexcept>
#include <chrono>
#include <cstring>
#include <cstdio>
struct USB {
    libusb_context *context=nullptr;
    libusb_device_handle *handle=nullptr;
    int interfaceNumber=-1;
    unsigned char input=0, output=0, tag=0;
    bool remote=false, gone=false, claimed=false, overlap=false;
    ScopeQueryTiming timing{}; int speed=0, maxPacket=0;
    static double now(){ return std::chrono::duration<double,std::milli>(std::chrono::steady_clock::now().time_since_epoch()).count(); }
    ~USB() {
        if(handle) {
            if(remote && !gone) { try{returnLocal();}catch(...){} }
            if(claimed) libusb_release_interface(handle,interfaceNumber);
            libusb_close(handle);
        }
        if(context) libusb_exit(context);
    }
    void check(int n,const char *op) {
        if(n == LIBUSB_ERROR_NO_DEVICE) gone=true;
        if(n<0) throw std::runtime_error(std::string(op)+": "+libusb_error_name(n));
    }
    void returnLocal() {
        if(!handle||gone)throw std::runtime_error("USB device unavailable during local-control cleanup");
        if(!remote)return;
        std::string errors;
        // GOTO_LOCAL is distinct from merely deasserting REN. Both requests
        // must be attempted even if the first one fails; no SCPI is sent afterward.
        for(int request:{161,160}) {
            unsigned char status=0;
            int n=libusb_control_transfer(handle,0xa1,request,0,interfaceNumber,&status,1,1000);
            if(n==LIBUSB_ERROR_NO_DEVICE)gone=true;
            if(n!=1||status!=1)errors += std::string(request==161 ? "Go To Local":"REN off")+" failed ("+std::to_string(n)+", status "+std::to_string(status)+"); ";
        }
        if(errors.empty())remote=false;else throw std::runtime_error(errors);
    }
    unsigned char next() { if(++tag==0) ++tag; return tag; }
    std::vector<uint8_t> header(int id,int t,uint32_t size,int flags) {
        std::vector<uint8_t> b(12); b[0]=id;b[1]=t;b[2]=uint8_t(~t);
        for(int i=0;i<4;++i)b[4+i]=uint8_t(size>>(8*i)); b[8]=flags; return b;
    }
    void send(std::vector<uint8_t> b) {
        int n=0; check(libusb_bulk_transfer(handle,output,b.data(),int(b.size()),&n,3000),"USB write");
        if(n!=int(b.size()))throw std::runtime_error("Incomplete USB write");
    }
    void write(const char *command) {
        std::string s(command); if(s.empty()||s.back()!='\n') s+='\n';
        auto b=header(1,next(),uint32_t(s.size()),1);b.insert(b.end(),s.begin(),s.end());
        while(b.size()%4)b.push_back(0);send(b);
    }
    struct Pending {
        int done=0, actual=0;
        libusb_transfer_status status=LIBUSB_TRANSFER_ERROR;
        double finished=0;
    };
    static void completed(libusb_transfer *transfer) {
        auto *state=static_cast<Pending*>(transfer->user_data);
        state->status=transfer->status;state->actual=transfer->actual_length;state->finished=now();state->done=1;
    }
    static int transferError(libusb_transfer_status status) {
        switch(status) {
            case LIBUSB_TRANSFER_COMPLETED:return 0;
            case LIBUSB_TRANSFER_TIMED_OUT:return LIBUSB_ERROR_TIMEOUT;
            case LIBUSB_TRANSFER_CANCELLED:return LIBUSB_ERROR_INTERRUPTED;
            case LIBUSB_TRANSFER_STALL:return LIBUSB_ERROR_PIPE;
            case LIBUSB_TRANSFER_NO_DEVICE:return LIBUSB_ERROR_NO_DEVICE;
            case LIBUSB_TRANSFER_OVERFLOW:return LIBUSB_ERROR_OVERFLOW;
            default:return LIBUSB_ERROR_IO;
        }
    }
    int response(unsigned char tag,std::vector<uint8_t> &bytes,bool concurrent) {
        auto request=header(2,tag,65536,0);
        if(!concurrent) {
            double t=now();send(request);timing.request_ms+=now()-t;
            int n=0;t=now();int result=libusb_bulk_transfer(handle,input,bytes.data(),int(bytes.size()),&n,3000);
            timing.read_ms+=now()-t;++timing.read_calls;timing.wire_bytes+=uint32_t(std::max(0,n));check(result,"USB read");return n;
        }
        using Transfer=std::unique_ptr<libusb_transfer,decltype(&libusb_free_transfer)>;
        Transfer out(libusb_alloc_transfer(0),libusb_free_transfer),in(libusb_alloc_transfer(0),libusb_free_transfer);
        if(!out||!in)throw std::runtime_error("Cannot allocate asynchronous USB transfers");
        Pending sent,received;
        libusb_fill_bulk_transfer(out.get(),handle,output,request.data(),int(request.size()),completed,&sent,3000);
        libusb_fill_bulk_transfer(in.get(),handle,input,bytes.data(),int(bytes.size()),completed,&received,3000);
        double outStart=now();check(libusb_submit_transfer(out.get()),"Queue USB read request");
        double inStart=now();int submitRead=libusb_submit_transfer(in.get());
        if(submitRead<0)libusb_cancel_transfer(out.get());
        int eventError=0;
        // Both buffers and callback states stay alive until every submitted transfer completes,
        // including on errors/cancellation. No synchronous USB call is made by the callback.
        while(!sent.done || (submitRead>=0 && !received.done)) {
            timeval timeout{0,100000};int r=libusb_handle_events_timeout(context,&timeout);
            if(r<0 && r!=LIBUSB_ERROR_INTERRUPTED && !eventError) {
                eventError=r;if(!sent.done)libusb_cancel_transfer(out.get());
                if(submitRead>=0&&!received.done)libusb_cancel_transfer(in.get());
            }
        }
        timing.overlapped=1;timing.request_ms+=sent.finished-outStart;
        if(submitRead>=0){timing.read_ms+=received.finished-inStart;++timing.read_calls;timing.wire_bytes+=uint32_t(std::max(0,received.actual));}
        check(submitRead,"Queue USB response");check(eventError,"USB event handling");
        check(transferError(sent.status),"USB read-request write");
        if(sent.actual!=int(request.size()))throw std::runtime_error("Incomplete USB read-request write");
        check(transferError(received.status),"USB response read");return received.actual;
    }
    std::vector<uint8_t> query(const char *command,int limit) {
        timing={};timing.link_speed=speed;timing.max_packet_bytes=maxPacket;
        const double queryStart=now();
        struct Finish { ScopeQueryTiming &timing; double start; ~Finish(){timing.total_ms=USB::now()-start;} } finish{timing,queryStart};
        double t=now();write(command);timing.command_ms=now()-t;std::vector<uint8_t> result;
        auto start=std::chrono::steady_clock::now();
        for(;;) {
            if(std::chrono::steady_clock::now()-start>std::chrono::seconds(15))throw std::runtime_error("USB message exceeded 15 seconds");
            auto tag=next();std::vector<uint8_t>b(65536+512);
            int n=response(tag,b,overlap && std::string(command)==":PRIVate:WAVeform:DATA:ALL?");
            if(n<12||b[0]!=2||b[1]!=tag||b[2]!=uint8_t(~tag))throw std::runtime_error("Invalid USBTMC header/tag");
            uint32_t size=0;for(int i=0;i<4;++i)size|=uint32_t(b[4+i])<<(8*i);
            if(size>uint32_t(n-12)||result.size()+size>size_t(limit))throw std::runtime_error("USB response exceeds bounds");
            timing.payload_bytes+=size;result.insert(result.end(),b.begin()+12,b.begin()+12+size);if(b[8]&1)return result;
        }
    }
    void open() {
        check(libusb_init(&context),"Initialize USB");libusb_device **list=nullptr;
        auto count=libusb_get_device_list(context,&list);check(int(count),"Enumerate USB");int matches=0, openError=0;
        for(ssize_t i=0;i<count;++i) {
            libusb_device_descriptor d{};
            if(libusb_get_device_descriptor(list[i],&d)<0||d.idVendor!=0x049f||d.idProduct!=0x505e)continue;
            libusb_device_handle *candidate=nullptr;int r=libusb_open(list[i],&candidate);
            if(r<0){openError=r;continue;}++matches;if(!handle)handle=candidate;else libusb_close(candidate);
        }
        libusb_free_device_list(list,1);
        if(!handle){if(openError)check(openError,"Open DSO2D15; close other scope apps");throw std::runtime_error("DSO2D15 not found. Check rear USB connection and power.");}
        if(matches>1)throw std::runtime_error("Connect only one DSO2D15");
        libusb_config_descriptor *config=nullptr;check(libusb_get_active_config_descriptor(libusb_get_device(handle),&config),"Read USB configuration");int alternate=0;
        for(int i=0;i<config->bNumInterfaces&&interfaceNumber<0;++i)for(int j=0;j<config->interface[i].num_altsetting;++j) {
            const auto &a=config->interface[i].altsetting[j];if(a.bInterfaceClass!=0xfe||a.bInterfaceSubClass!=3)continue;
            uint8_t in=0,out=0;for(int e=0;e<a.bNumEndpoints;++e){auto ep=a.endpoint[e];if((ep.bmAttributes&3)!=2)continue;if(ep.bEndpointAddress&0x80)in=ep.bEndpointAddress;else out=ep.bEndpointAddress;}
            if(in&&out){interfaceNumber=a.bInterfaceNumber;alternate=a.bAlternateSetting;input=in;output=out;for(int e=0;e<a.bNumEndpoints;++e)if(a.endpoint[e].bEndpointAddress==in)maxPacket=a.endpoint[e].wMaxPacketSize;break;}
        }
        speed=libusb_get_device_speed(libusb_get_device(handle));
        libusb_free_config_descriptor(config);if(interfaceNumber<0)throw std::runtime_error("No USBTMC bulk interface");
        libusb_set_auto_detach_kernel_driver(handle,1);check(libusb_claim_interface(handle,interfaceNumber),"Claim USB interface");claimed=true;
        if(alternate)check(libusb_set_interface_alt_setting(handle,interfaceNumber,alternate),"Select USB interface");
        unsigned char caps[24]{};int n=libusb_control_transfer(handle,0xa1,7,0,interfaceNumber,caps,24,3000);check(n,"Read capabilities");
        if(n<15||caps[0]!=1)throw std::runtime_error("Invalid USBTMC capabilities");
        if(caps[14]&2){unsigned char s=0;int r=libusb_control_transfer(handle,0xa1,160,1,interfaceNumber,&s,1,3000);check(r,"Enable remote");if(r!=1||s!=1)throw std::runtime_error("Remote control rejected");remote=true;}
    }
};
static void errorText(char *out,int capacity,const std::exception &e){if(capacity>0)snprintf(out,capacity,"%s",e.what());}
extern "C" void *scope_open(char *error,int capacity){auto *p=new USB;try{p->open();return p;}catch(const std::exception&e){errorText(error,capacity,e);delete p;return nullptr;}}
extern "C" int scope_write(void *p,const char *command,char *error,int capacity){try{static_cast<USB*>(p)->write(command);return 0;}catch(const std::exception&e){errorText(error,capacity,e);return -1;}}
extern "C" int scope_query(void *p,const char *command,uint8_t *bytes,int capacity,char *error,int ec){try{auto r=static_cast<USB*>(p)->query(command,capacity);memcpy(bytes,r.data(),r.size());return int(r.size());}catch(const std::exception&e){errorText(error,ec,e);return -1;}}
extern "C" void scope_close(void *p){delete static_cast<USB*>(p);}

extern "C" int scope_query_profiled(void *p,const char *command,uint8_t *bytes,int capacity,ScopeQueryTiming *timing,char *error,int ec){
    auto *usb=static_cast<USB*>(p);
    try{auto result=usb->query(command,capacity);memcpy(bytes,result.data(),result.size());if(timing)*timing=usb->timing;return int(result.size());}
    catch(const std::exception&e){if(timing)*timing=usb->timing;errorText(error,ec,e);return -1;}
}

extern "C" void scope_set_overlap(void *p,int enabled){if(p)static_cast<USB*>(p)->overlap=enabled!=0;}

extern "C" int scope_return_local(void *p,char *error,int capacity){try{if(p)static_cast<USB*>(p)->returnLocal();return 0;}catch(const std::exception&e){errorText(error,capacity,e);return -1;}}
