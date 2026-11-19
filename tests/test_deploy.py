import os
from pathlib import Path
import shutil
import struct
import subprocess
import tempfile
import unittest
import zipfile


SCRIPT = Path(__file__).resolve().parents[1] / 'scripts' / 'deploy.ps1'


class DeployTests(unittest.TestCase):
    def setUp(self):
        self.root = Path(tempfile.mkdtemp(prefix='yb-map-deploy-test-'))
        self.repo = self.root / 'repo'
        self.profile = self.root / 'profile'
        self.mod = self.repo / 'mod'
        self.installed = self.profile / 'Documents/Paradox Interactive/Crusader Kings III/mod/yb_map'
        (self.repo / 'scripts').mkdir(parents=True)
        self.mod.mkdir()
        (self.repo / 'dist').mkdir()
        self.installed.parent.mkdir(parents=True)
        shutil.copyfile(SCRIPT, self.repo / 'scripts/deploy.ps1')
        subprocess.run(['git', 'init', '-q', str(self.repo)], check=True)
        self.write(self.mod / 'descriptor.mod', 'version="1.0"\n')
        self.write(self.repo / 'yb_map.mod', 'version="1.0"\npath="mod/yb_map"\n')
        self.write(self.mod / 'gfx/old.txt', 'old managed content')
        self.write(self.mod / 'gfx/keep.txt', 'kept content')
        self.package()

    def tearDown(self):
        # Keep deletion reversible, including the isolated test repository.
        env = os.environ.copy()
        env['YB_TEST_ROOT'] = str(self.root)
        subprocess.run([
            'pwsh', '-NoProfile', '-Command',
            'Add-Type -AssemblyName Microsoft.VisualBasic; '
            '[Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory('
            '$env:YB_TEST_ROOT,"OnlyErrorDialogs","SendToRecycleBin")'
        ], check=True, capture_output=True, text=True, env=env)

    @staticmethod
    def write(path, value):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(value, encoding='utf-8')

    def package(self):
        with zipfile.ZipFile(self.repo / 'dist/yb_map-1.0.zip', 'w', zipfile.ZIP_DEFLATED) as archive:
            archive.write(self.repo / 'yb_map.mod', 'yb_map.mod')
            for file in self.mod.rglob('*'):
                if file.is_file():
                    relative = file.relative_to(self.mod).as_posix()
                    if relative == 'gfx/map/terrain/flat_maps/flatmap_yb.dds':
                        data = bytearray(21233792)
                        data[:4] = b'DDS '
                        struct.pack_into('<I', data, 12, 4608)
                        struct.pack_into('<I', data, 16, 9216)
                        data[84:88] = b'DXT1'
                        archive.writestr('yb_map/' + relative, data)
                    else:
                        archive.write(file, 'yb_map/' + relative)

    def deploy(self, *args, success=True):
        env = os.environ.copy()
        env['USERPROFILE'] = str(self.profile)
        result = subprocess.run(
            ['pwsh', '-NoProfile', '-NonInteractive', '-File', str(self.repo / 'scripts/deploy.ps1'), *args],
            cwd=self.repo, env=env, capture_output=True, text=True,
        )
        if success:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        return result

    def snapshot_ids(self):
        base = self.repo / 'development/local/deployments'
        return sorted(p.name for p in base.iterdir() if p.is_dir()) if base.exists() else []

    def remove_source(self):
        # The source file is moved aside rather than permanently deleted.
        (self.mod / 'gfx/old.txt').rename(self.root / 'old-source.txt')
        self.package()

    def test_delete_managed_preserve_user_and_rollback(self):
        self.deploy()
        self.write(self.installed / 'gfx/user.txt', 'user data')
        self.remove_source()
        before = self.snapshot_ids()
        self.deploy('-WhatIf')
        self.assertEqual(self.snapshot_ids(), before)
        self.assertTrue((self.installed / 'gfx/old.txt').exists())
        self.deploy()
        self.assertFalse((self.installed / 'gfx/old.txt').exists())
        self.assertEqual((self.installed / 'gfx/user.txt').read_text(), 'user data')
        new = sorted(set(self.snapshot_ids()) - set(before))
        self.assertEqual(len(new), 1)
        self.deploy('-Rollback', new[0])
        self.assertEqual((self.installed / 'gfx/old.txt').read_text(), 'old managed content')
        self.assertEqual((self.installed / 'gfx/user.txt').read_text(), 'user data')

    def test_modified_removed_file_is_not_deleted(self):
        self.deploy()
        self.write(self.installed / 'gfx/old.txt', 'user modified')
        self.remove_source()
        self.deploy(success=False)
        self.assertEqual((self.installed / 'gfx/old.txt').read_text(), 'user modified')

    def test_rollback_refuses_recreated_file(self):
        self.deploy()
        self.remove_source()
        before = self.snapshot_ids()
        self.deploy()
        new = sorted(set(self.snapshot_ids()) - set(before))
        self.assertEqual(len(new), 1)
        self.write(self.installed / 'gfx/old.txt', 'new user file')
        self.deploy('-Rollback', new[0], success=False)
        self.assertEqual((self.installed / 'gfx/old.txt').read_text(), 'new user file')

    def test_existing_install_without_inventory_bootstraps_safely(self):
        self.deploy()
        deployments = self.repo / 'development/local/deployments'
        deployments.rename(self.root / 'previous-deployments')
        self.write(self.installed / 'gfx/unmanaged.txt', 'preserve me')
        self.deploy('-WhatIf')
        self.assertFalse(deployments.exists())
        self.deploy()
        self.assertEqual((self.installed / 'gfx/unmanaged.txt').read_text(), 'preserve me')
        self.remove_source()
        self.deploy()
        self.assertFalse((self.installed / 'gfx/old.txt').exists())
        self.assertEqual((self.installed / 'gfx/unmanaged.txt').read_text(), 'preserve me')

    def test_packed_flatmap_hash_is_used_for_removal(self):
        relative = Path('gfx/map/terrain/flat_maps/flatmap_yb.dds')
        self.write(self.mod / relative, 'source differs from generated DDS')
        self.package()
        self.deploy()
        (self.mod / relative).rename(self.root / 'flatmap-source.dds')
        self.package()
        self.deploy()
        self.assertFalse((self.installed / relative).exists())

    def test_two_rollbacks_restore_inventory_for_next_deploy(self):
        self.deploy()
        before = self.snapshot_ids()
        self.write(self.mod / 'gfx/new.txt', 'new managed content')
        self.package()
        self.deploy()
        first = (set(self.snapshot_ids()) - set(before)).pop()
        before = self.snapshot_ids()
        self.remove_source()
        self.deploy()
        second = (set(self.snapshot_ids()) - set(before)).pop()
        self.deploy('-Rollback', second)
        self.assertTrue((self.installed / 'gfx/old.txt').exists())
        self.deploy('-Rollback', first)
        self.assertFalse((self.installed / 'gfx/new.txt').exists())
        (self.mod / 'gfx/new.txt').rename(self.root / 'new-source.txt')
        self.package()
        self.deploy()
        self.assertFalse((self.installed / 'gfx/old.txt').exists())


if __name__ == '__main__':
    unittest.main()
