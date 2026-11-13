"""Rebrand localized browser UI at repack time; retain IDs and translations.

Only locale text is changed. URLs, technical names, and Chromium attribution
remain intact. Keeping this outside the GRD sources avoids translation-ID churn
and a large patch to rebase for every Chromium update.
"""
import re

_BRAND = re.compile(r'(?<![A-Za-z0-9_])Chromium(?![A-Za-z0-9_])')
_URL = re.compile(r'(?:https?|chrome|chrome-extension)://[^\s<>\"\']+')
_LEGAL = re.compile(r'COPYRIGHT|LICENSE|CREDITS|TERMS_|ABOUT_VERSION_COMPANY_NAME')


def rebrand_text(name, value):
    if _LEGAL.search(name) or 'Chromium Authors' in value:
        return value
    # Transform text between URLs so a product name in a URL stays byte-exact.
    parts = []
    offset = 0
    for match in _URL.finditer(value):
        parts.extend((_BRAND.sub('Bark', value[offset:match.start()]), match.group()))
        offset = match.end()
    parts.append(_BRAND.sub('Bark', value[offset:]))
    return ''.join(parts)


def rebrand_pak(pak_path, info_path, data_pack):
    pak = data_pack.ReadDataPack(pak_path)
    if pak.encoding not in (data_pack.UTF8, data_pack.UTF16):
        raise ValueError('Bark branding is only valid for localized text packs')
    encoding = 'utf-8' if pak.encoding == data_pack.UTF8 else 'utf-16-le'
    names = {}
    with open(info_path, encoding='utf-8') as source:
        for line in source:
            name, identifier, _ = line.rstrip('\n').split(',', 2)
            names[int(identifier)] = name
    resources = {}
    for identifier, payload in pak.resources.items():
        # Locale packs also contain compressed JSON/data resources. Only IDS
        # entries are UI strings; preserve every other payload byte-for-byte.
        name = names.get(identifier, '')
        if not name.startswith('IDS_') or _LEGAL.search(name) or payload.startswith(b'\x1f\x8b'):
            resources[identifier] = payload
            continue
        value = payload.decode(encoding)
        value = rebrand_text(name, value)
        resources[identifier] = value.encode(encoding)
    data_pack.WriteDataPack(resources, pak_path, pak.encoding)
