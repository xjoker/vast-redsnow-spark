import os
import stat
import sys
import tempfile
import zipfile

sys.path.insert(0, os.path.dirname(os.path.dirname(os.path.abspath(__file__))))

import install_easytier


def test_installs_both_binaries_from_one_zip():
    with tempfile.TemporaryDirectory() as root:
        archive = os.path.join(root, "easytier.zip")
        dest = os.path.join(root, "bin")
        with zipfile.ZipFile(archive, "w") as bundle:
            bundle.writestr("easytier-linux-aarch64/easytier-core", b"core-bytes")
            bundle.writestr("easytier-linux-aarch64/easytier-cli", b"cli-bytes")
            bundle.writestr("easytier-linux-aarch64/easytier-web", b"not-installed")
        install_easytier.install(archive, dest)
        for name, body in (("easytier-core", b"core-bytes"), ("easytier-cli", b"cli-bytes")):
            path = os.path.join(dest, name)
            with open(path, "rb") as handle:
                assert handle.read() == body
            assert stat.S_IMODE(os.stat(path).st_mode) == 0o755
        assert not os.path.exists(os.path.join(dest, "easytier-web"))


if __name__ == "__main__":
    test_installs_both_binaries_from_one_zip()
    print("install_easytier ok")
