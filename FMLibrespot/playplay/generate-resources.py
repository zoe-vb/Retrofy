"""Generate local PlayPlay build inputs from Spotiya's pinned decoder archive."""

import hashlib
import sys
import tarfile
from pathlib import Path


def write_array(out, declaration, data):
    out.write(f"static const uint8_t {declaration} = {{\n")
    for offset in range(0, len(data), 24):
        out.write(",".join(f"0x{byte:02x}" for byte in data[offset:offset + 24]) + ",\n")
    out.write("};\n")


archive_path, output = map(Path, sys.argv[1:])
with tarfile.open(archive_path, "r:gz") as archive:
    decoder = archive.extractfile("spotiya-playplay/playplay/bin/playplay-decoder").read()

# File offsets in the pinned v0.9.3 ARMv7 add-on, checked by build-ios6.sh.
image_offset = 0x525EC
image = decoder[image_offset:image_offset + 659456]
if hashlib.sha256(image).hexdigest() != "82c8cee4e4e8cd840664cb1e2df4f4780cfa4a48997a931e2d6013cdd251d5ae":
    raise SystemExit("Unexpected PlayPlay guest image")

with (output / "resources.h").open("w") as out:
    out.write('#include "resources-layout.h"\n')
    write_array(out, "initial_image[]", image)
    out.write('_Static_assert(sizeof(initial_image) == sizeof(image_pages) / sizeof(image_pages[0]) * 4096, "image shape");\n')

token_offset = 0x6817C - image_offset
with (output / "playplay-token.h").open("w") as out:
    write_array(out, "playplay_build_token[16]", image[token_offset:token_offset + 16])
