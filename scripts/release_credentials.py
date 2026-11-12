# SPDX-License-Identifier: GPL-3.0-or-later
# Credential lookup adapted from BitSkim; see ThirdParty/BitSkim/LICENSE.
"""Resolve API tokens only when publishing; never persist or display secret output."""
import json
import os
import re
import subprocess

from build_provenance import ReleaseError, require

SERVICES = {'github', 'gitlab'}


def validate_credentials(settings):
    require(isinstance(settings, dict) and set(settings) <= SERVICES, 'Unknown credential service')
    for service, spec in settings.items():
        require(isinstance(spec, dict), 'Invalid credential descriptor for ' + service)
        provider = spec.get('provider', 'env')
        allowed = {'provider', 'variable'} if provider == 'env' else {'provider', 'reference', 'vault', 'item', 'field', 'account'}
        require(provider in {'env', '1password'} and set(spec) <= allowed,
                'Use environment or 1Password credential descriptors, never literal tokens')
        require(all(isinstance(v, str) and (v or key == 'account') and '\n' not in v and '\r' not in v
                    and not v.startswith('-') for key, v in spec.items()), 'Invalid credential descriptor')
        if provider == 'env':
            require(re.fullmatch(r'[A-Za-z_][A-Za-z0-9_]*', spec.get('variable', service.upper() + '_TOKEN')),
                    'Invalid token environment variable name')
        elif spec.get('reference'):
            require(spec['reference'].startswith('op://') and len(spec['reference'][5:].split('/')) >= 3
                    and all(spec['reference'][5:].split('/')), 'Invalid 1Password reference')
            require(not any(k in spec for k in ('vault', 'item', 'field')), 'Choose a reference or a vault/item/field descriptor')
        else:
            require(all(spec.get(k) for k in ('vault', 'item', 'field')), 'Configure 1Password vault, item and field')


def credential(service, config):
    settings = config.get('credentials', {})
    validate_credentials(settings)
    spec = settings.get(service, {})
    if spec.get('provider', 'env') == 'env':
        token = os.environ.get(spec.get('variable', service.upper() + '_TOKEN'), '')
    else:
        reference = spec.get('reference')
        if reference:
            command = ['op', 'read', '--no-newline', reference]
        else:
            command = ['op', 'item', 'get', spec['item'], '--vault', spec['vault'], '--fields',
                       'label=' + spec['field'], '--format', 'json', '--reveal']
        if spec.get('account'):
            command += ['--account', spec['account']]
        try:
            result = subprocess.run(command, capture_output=True, text=True)
        except OSError:
            raise ReleaseError('1Password CLI is unavailable for ' + service + '; no secret output displayed') from None
        require(result.returncode == 0, '1Password lookup failed or was cancelled for ' + service + '; no secret output displayed')
        if reference:
            token = result.stdout
        else:
            try:
                data = json.loads(result.stdout)
                fields = data if isinstance(data, list) else data.get('fields', [data])
                matches = [f for f in fields if f.get('label') == spec['field'] and f.get('value')]
                require(len(matches) == 1, '1Password field is missing or ambiguous for ' + service)
                token = matches[0]['value']
            except (ValueError, KeyError, TypeError, AttributeError):
                raise ReleaseError('Invalid 1Password field response for ' + service + '; no secret output displayed') from None
    require(isinstance(token, str) and token.strip() and not token.strip().startswith('op://'),
            'Missing/unresolved token for ' + service + '; configure 1Password or its token environment variable')
    token = token.strip()
    require(not any(c.isspace() for c in token), 'Invalid token format for ' + service)
    return token
