import 'package:veritag_app/binding.dart';
import 'package:convert/convert.dart';
import 'package:flutter_test/flutter_test.dart';

/// The mobile app builds the Veritag domain binding byte-identically to the
/// Python backend (veritag-core arttrust/binding.py) and the web portal, so a tag
/// minted on mobile matches one minted on web. Expected values from binding.py.
void main() {
  test('veritagBinding matches the Python backend', () {
    expect(
      hex.encode(veritagBinding('04D2760000850100', 'Composition VIII', 'artist_0042')),
      equals('b958f7c3cc046a676532abc14aeb0744a394da8c93036bc6950eb010ae1d2600'),
    );
    expect(
      hex.encode(veritagBinding('AABBCCDDEEFF0011', 'Café Terrace', 'artist_0099')),
      equals('27aa7e6819afbc4459a3bdcc888f7d9662e2512058f5ff423165de23536e52ac'),
    );
  });
}
