// SPDX-License-Identifier: GPL-3.0-or-later
// Exercise queue ordering and transfer lifetime without instrument access.
#include <libusb.h>
#include <vector>
#include <cassert>
#include <cstring>
#include <iostream>
int fakeControl(libusb_device_handle*,uint8_t,uint8_t,uint16_t,uint16_t,unsigned char*,uint16_t,unsigned int);
int fakeSubmit(libusb_transfer*);
int fakeCancel(libusb_transfer*);
int fakeEvents(libusb_context*,timeval*);
int fakeBulk(libusb_device_handle*,unsigned char,unsigned char*,int,int*,unsigned int);
#define libusb_control_transfer fakeControl
#define libusb_submit_transfer fakeSubmit
#define libusb_cancel_transfer fakeCancel
#define libusb_handle_events_timeout fakeEvents
#define libusb_bulk_transfer fakeBulk
#include "../Bridge/ScopeUSB.cpp"
#undef libusb_control_transfer
#undef libusb_submit_transfer
#undef libusb_cancel_transfer
#undef libusb_handle_events_timeout
#undef libusb_bulk_transfer

enum Mode { Good, ShortWrite, OutTimeout, InTimeout, SubmitFailure, EventFailure, Gone };
std::vector<int> controls;bool failLocal=false;
int fakeControl(libusb_device_handle*,uint8_t,uint8_t request,uint16_t value,uint16_t,unsigned char *bytes,uint16_t,unsigned int){assert(value==0);controls.push_back(request);bytes[0]=(request==161&&failLocal)?0x80:1;return 1;}
Mode mode=Good;std::vector<libusb_transfer*> pending;unsigned char responseTag=1;bool eventFailed=false;
int fakeSubmit(libusb_transfer *t) {
    if((t->endpoint&0x80)&&mode==SubmitFailure)return LIBUSB_ERROR_IO;
    if(!(t->endpoint&0x80))responseTag=t->buffer[1];
    pending.push_back(t);return 0;
}
int fakeCancel(libusb_transfer *t){t->status=LIBUSB_TRANSFER_CANCELLED;return 0;}
static void reply(unsigned char *bytes,int *length) {
    memset(bytes,0,13);bytes[0]=2;bytes[1]=responseTag;bytes[2]=uint8_t(~responseTag);bytes[4]=1;bytes[8]=1;bytes[12]='x';*length=13;
}
int fakeEvents(libusb_context*,timeval*) {
    if(mode==EventFailure&&!eventFailed){eventFailed=true;return LIBUSB_ERROR_IO;}
    auto active=pending;pending.clear();
    for(auto *t:active) {
        if(t->status!=LIBUSB_TRANSFER_CANCELLED) {
            bool in=t->endpoint&0x80;t->status=LIBUSB_TRANSFER_COMPLETED;
            if(in)reply(t->buffer,&t->actual_length);else t->actual_length=t->length;
            if((!in&&mode==OutTimeout)||(in&&mode==InTimeout))t->status=LIBUSB_TRANSFER_TIMED_OUT;
            if(in&&mode==Gone)t->status=LIBUSB_TRANSFER_NO_DEVICE;
            if(!in&&mode==ShortWrite)t->actual_length=t->length-1;
        }
        t->callback(t);
    }return 0;
}
int fakeBulk(libusb_device_handle*,unsigned char endpoint,unsigned char *bytes,int length,int *n,unsigned int){
    if(endpoint&0x80)reply(bytes,n);else{*n=length;if(bytes[0]==2)responseTag=bytes[1];}return 0;
}
struct TestUSB:USB { TestUSB(){handle=reinterpret_cast<libusb_device_handle*>(1);input=0x81;output=2;speed=3;maxPacket=512;}~TestUSB(){handle=nullptr;} };
int main(){
    {TestUSB usb;usb.remote=true;usb.returnLocal();assert((controls==std::vector<int>{161,160}));assert(!usb.remote);usb.returnLocal();assert(controls.size()==2);}
    controls.clear();failLocal=true;
    {TestUSB usb;usb.remote=true;bool rejected=false;try{usb.returnLocal();}catch(const std::exception&){rejected=true;}assert(rejected);assert((controls==std::vector<int>{161,160}));}
    controls.clear();failLocal=false;
    for(int i=0;i<100;++i){TestUSB usb;usb.remote=true;usb.returnLocal();}
    assert(controls.size()==200);controls.clear();
    std::cout<<"Go To Local before REN off, idempotent cleanup and error reporting verified.\n";

    {TestUSB usb;auto bytes=usb.query(":PRIVate:WAVeform:DATA:ALL?",1024);assert(bytes==std::vector<uint8_t>{'x'});assert(usb.timing.overlapped==0);}
    {TestUSB usb;usb.overlap=true;auto bytes=usb.query(":PRIVate:WAVeform:DATA:ALL?",1024);assert(bytes==std::vector<uint8_t>{'x'});assert(usb.timing.overlapped==1);assert(usb.timing.read_calls==1);assert(pending.empty());}
    {TestUSB usb;usb.overlap=true;usb.query(":RUNning?",1024);assert(usb.timing.overlapped==0);}
    for(auto failure:{ShortWrite,OutTimeout,InTimeout,SubmitFailure,EventFailure,Gone}){
        mode=failure;eventFailed=false;TestUSB usb;usb.overlap=true;bool rejected=false;
        try{usb.query(":PRIVate:WAVeform:DATA:ALL?",1024);}catch(const std::exception&){rejected=true;}
        assert(rejected);assert(pending.empty());if(mode==Gone)assert(usb.gone);
    }
    std::cout<<"USB sequential/overlap framing, waveform-only selection, short write, timeout, submit failure, event failure, disconnect and callback cleanup passed.\n";
}
