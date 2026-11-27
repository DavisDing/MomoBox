class ProductBarcode {
  const ProductBarcode(
    this.number, {
    this.batchNo,
    this.productionDate,
    this.expiryDate,
    this.datePrecision = 'day',
  });

  final String number;
  final String? batchNo;
  final DateTime? productionDate;
  final DateTime? expiryDate;
  final String datePrecision;

  bool get hasBatchData =>
      batchNo != null || productionDate != null || expiryDate != null;

  static ProductBarcode? parse(
    String? input, {
    bool elementString = false,
    int? year,
  }) {
    final value = input?.trim();
    if (value == null || value.isEmpty || value.length > 2048) return null;
    if (RegExp(r'^\d{8,14}$').hasMatch(value)) return ProductBarcode(value);

    final Map<String, String>? fields;
    if (value.startsWith('https://') || value.startsWith('http://')) {
      fields = _digitalLink(value);
    } else if (value.startsWith('(')) {
      fields = _parenthesized(value);
    } else if (elementString || RegExp(r'^\](d2|C1|Q3)').hasMatch(value)) {
      fields = _elements(value.replaceFirst(RegExp(r'^\](d2|C1|Q3)'), ''));
    } else {
      return null;
    }
    final gtin = fields?['01'];
    if (gtin == null || gtin.length != 14 || !_isValidGtin(gtin)) return null;
    var number = gtin;
    for (final variant in equivalents(gtin)) {
      if (variant.length < number.length) number = variant;
    }
    final currentYear = year ?? DateTime.now().year;
    final production = _date(fields?['11'], currentYear);
    final expiry = _date(fields?['17'], currentYear);
    final safeExpiry =
        production != null && expiry != null && expiry.isBefore(production)
            ? null
            : expiry;
    final batch = fields?['10'];
    return ProductBarcode(
      number,
      batchNo: batch != null && _batch.hasMatch(batch) ? batch : null,
      productionDate: production,
      expiryDate: safeExpiry,
      datePrecision:
          (production != null && fields!['11']!.endsWith('00') ||
                  safeExpiry != null && fields!['17']!.endsWith('00'))
              ? 'month'
              : 'day',
    );
  }

  static Set<String> equivalents(String number) {
    if (!_isValidGtin(number)) return {number};
    final padded = number.padLeft(14, '0');
    return {
      for (final length in const [8, 12, 13, 14])
        if (padded.substring(0, 14 - length).replaceAll('0', '').isEmpty)
          padded.substring(14 - length),
    };
  }

  static bool _isValidGtin(String value) {
    if (!const {8, 12, 13, 14}.contains(value.length) ||
        !RegExp(r'^\d+$').hasMatch(value) ||
        value.replaceAll('0', '').isEmpty) {
      return false;
    }
    var sum = 0;
    for (var i = 0; i < value.length; i++) {
      sum +=
          (value.codeUnitAt(i) - 48) * ((value.length - 1 - i).isEven ? 1 : 3);
    }
    return sum % 10 == 0;
  }

  static final _batch = RegExp(r'^[!-~]{1,20}$');
  static const _fixedLengths = {
    '01': 14,
    '11': 6,
    '13': 6,
    '15': 6,
    '16': 6,
    '17': 6,
  };

  static Map<String, String>? _digitalLink(String value) {
    final uri = Uri.tryParse(value);
    if (uri == null || uri.host.isEmpty || uri.userInfo.isNotEmpty) return null;
    final path = uri.pathSegments;
    final start = path.indexOf('01');
    if (start < 0 || (path.length - start).isOdd) return null;
    final fields = <String, String>{};
    for (var i = start; i < path.length; i += 2) {
      final key = path[i];
      if (!const {'01', '10', '21', '22'}.contains(key) ||
          fields.containsKey(key)) {
        return null;
      }
      fields[key] = path[i + 1];
    }
    for (final key in const ['11', '17']) {
      final values = uri.queryParametersAll[key];
      if (values?.length == 1) fields[key] = values!.single;
    }
    return fields;
  }

  static Map<String, String>? _parenthesized(String value) {
    final markers = RegExp(r'\((\d{2,4})\)').allMatches(value).toList();
    if (markers.isEmpty || markers.first.start != 0) return null;
    final fields = <String, String>{};
    for (var i = 0; i < markers.length; i++) {
      final marker = markers[i];
      final key = marker.group(1)!;
      if (fields.containsKey(key)) return null;
      fields[key] = value.substring(
        marker.end,
        i + 1 == markers.length ? value.length : markers[i + 1].start,
      );
    }
    return fields;
  }

  static Map<String, String>? _elements(String value) {
    final fields = <String, String>{};
    const separator = '\u001d';
    var offset = value.startsWith(separator) ? 1 : 0;
    while (offset + 2 <= value.length) {
      final key = value.substring(offset, offset + 2);
      if (fields.containsKey(key)) return null;
      offset += 2;
      final length = _fixedLengths[key];
      final int end;
      if (length != null) {
        end = offset + length;
        if (end > value.length) return null;
      } else if (key == '10' || key == '21') {
        final next = value.indexOf(separator, offset);
        end = next < 0 ? value.length : next;
        if (end - offset > 20 || end == offset) return null;
      } else {
        return null;
      }
      fields[key] = value.substring(offset, end);
      offset = end;
      if (offset < value.length && value[offset] == separator) offset++;
    }
    return offset == value.length ? fields : null;
  }

  static DateTime? _date(String? value, int currentYear) {
    if (value == null || !RegExp(r'^\d{6}$').hasMatch(value)) return null;
    final yearSuffix = int.parse(value.substring(0, 2));
    final year = currentYear - 49 + (yearSuffix - (currentYear - 49)) % 100;
    final month = int.parse(value.substring(2, 4));
    final day = int.parse(value.substring(4, 6));
    if (month < 1 || month > 12) return null;
    final date =
        day == 0 ? DateTime(year, month + 1, 0) : DateTime(year, month, day);
    return date.month == month ? date : null;
  }
}
