#!/usr/bin/env python3
"""Check notification Gson metadata in the actual R8-produced release APK.

No Android tool installation is needed. This checks the DEX class annotations,
not merely the presence of signature strings or a source ProGuard rule.
"""
import argparse
import struct
import sys
import zipfile


class Dex:
    def __init__(self, data):
        self.data = data
        if not data.startswith(b'dex\n'):
            raise ValueError('Expected a standard DEX file')
        count, offset = self.words(56, 2)
        self.strings = []
        for i in range(count):
            pos = self.words(offset + 4 * i, 1)[0]
            _, pos = self.uleb(pos)
            end = data.index(b'\0', pos)
            self.strings.append(data[pos:end].decode('utf-8', errors='replace'))
        count, offset = self.words(64, 2)
        self.types = [self.strings[self.words(offset + 4 * i, 1)[0]]
                      for i in range(count)]
        count, offset = self.words(96, 2)
        self.classes = {}
        for i in range(count):
            row = self.words(offset + 32 * i, 8)
            self.classes[self.types[row[0]]] = row

    def words(self, offset, count):
        return struct.unpack_from('<' + 'I' * count, self.data, offset)

    def uleb(self, pos):
        value = shift = 0
        while True:
            byte = self.data[pos]
            pos += 1
            value |= (byte & 127) << shift
            if byte < 128:
                return value, pos
            shift += 7
            if shift > 28:
                raise ValueError('Invalid DEX ULEB128')

    def value(self, pos):
        header = self.data[pos]
        kind, width = header & 31, (header >> 5) + 1
        pos += 1
        if kind == 0x1c:  # encoded_array, used by dalvik.annotation.Signature
            count, pos = self.uleb(pos)
            values = []
            for _ in range(count):
                value, pos = self.value(pos)
                values.append(value)
            return values, pos
        if kind == 0x17:  # VALUE_STRING
            index = int.from_bytes(self.data[pos:pos + width], 'little')
            return self.strings[index], pos + width
        raise ValueError('Unexpected Signature annotation value')

    def signature(self, row):
        if not row[5]:
            return None
        annotations = self.words(row[5], 1)[0]
        if not annotations:
            return None
        count = self.words(annotations, 1)[0]
        for offset in self.words(annotations + 4, count):
            annotation_type, pos = self.uleb(offset + 1)  # skip visibility
            if self.types[annotation_type] != 'Ldalvik/annotation/Signature;':
                continue
            count, pos = self.uleb(pos)
            for _ in range(count):
                name, pos = self.uleb(pos)
                value, pos = self.value(pos)
                if self.strings[name] == 'value':
                    return ''.join(value)
        return None

    def fields(self, row):
        if not row[6]:
            return set()
        pos = row[6]
        counts = []
        for _ in range(4):
            count, pos = self.uleb(pos)
            counts.append(count)
        _, field_offset = self.words(80, 2)
        names = set()
        for count in counts[:2]:
            index = 0
            for _ in range(count):
                delta, pos = self.uleb(pos)
                _, pos = self.uleb(pos)  # access flags
                index += delta
                name = self.words(field_offset + 8 * index + 4, 1)[0]
                names.add(self.strings[name])
        return names


def verify(apk):
    token = 'Lcom/google/gson/reflect/TypeToken;'
    model = 'Lcom/dexterous/flutterlocalnotifications/models/NotificationDetails;'
    with zipfile.ZipFile(apk) as archive:
        dexes = [Dex(archive.read(name)) for name in archive.namelist()
                 if name.startswith('classes') and name.endswith('.dex')]
    classes = {name: (dex, row) for dex in dexes
               for name, row in dex.classes.items()}
    if token not in classes:
        raise ValueError('Gson TypeToken was removed/renamed; notification keep rules are missing')
    dex, row = classes[token]
    if not dex.signature(row):
        raise ValueError('Gson TypeToken generic Signature was stripped by R8')
    notification_tokens = 0
    for name, (dex, row) in classes.items():
        if (row[2] != 0xffffffff and dex.types[row[2]] == token and
                name.startswith('Lcom/dexterous/flutterlocalnotifications/')):
            signature = dex.signature(row)
            if not signature:
                raise ValueError(f'Notification TypeToken Signature was stripped: {name}')
            if model in signature:
                notification_tokens += 1
    if not notification_tokens:
        raise ValueError('No retained TypeToken<ArrayList<NotificationDetails>> signature')
    if model not in classes:
        raise ValueError('Persisted NotificationDetails class was removed/renamed')
    dex, row = classes[model]
    required = {'id', 'title', 'body', 'payload', 'scheduledDateTime'}
    missing = required - dex.fields(row)
    if missing:
        raise ValueError(f'Persisted notification fields were stripped/renamed: {sorted(missing)}')
    return notification_tokens


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--apk', required=True)
    args = parser.parse_args()
    try:
        count = verify(args.apk)
    except (ValueError, KeyError, IndexError, struct.error, zipfile.BadZipFile) as error:
        print(f'FAIL: notification release metadata: {error}', file=sys.stderr)
        return 1
    print(f'PASS: release APK retained notification Gson signatures ({count} schedule token) and fields')
    return 0


if __name__ == '__main__':
    sys.exit(main())
