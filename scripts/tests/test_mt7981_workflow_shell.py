from pathlib import Path
import re
import shutil
import subprocess
import unittest
import yaml


@unittest.skipUnless(shutil.which('bash'), 'requires Bash, as used by GitHub Actions')
class WorkflowShellTests(unittest.TestCase):
    def test_workflow_commands_parse_before_expensive_builds(self):
        path = Path(__file__).resolve().parents[2] / '.github/workflows/MT7981-FastACL255-MTWiFi.yml'
        workflow = yaml.safe_load(path.read_text(encoding='utf-8'))
        for job in workflow['jobs'].values():
            for step in job['steps']:
                if 'run' not in step:
                    continue
                command = re.sub(r'\$\{\{.*?\}\}', 'CI_VALUE', step['run'])
                with self.subTest(step=step.get('name')):
                    result = subprocess.run(['bash', '-n'], input=command, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)

    def test_catches_the_failed_collection_escaping(self):
        broken = r"find . \\( -name '*.bin' \\) -print" + '\n'
        result = subprocess.run(['bash', '-n'], input=broken, text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)


class BuildOrderTests(unittest.TestCase):
    def test_metadata_exists_before_standalone_package_compile(self):
        path = Path(__file__).resolve().parents[2] / '.github/workflows/MT7981-FastACL255-MTWiFi.yml'
        workflow = yaml.safe_load(path.read_text(encoding='utf-8'))
        command = next(step['run'] for step in workflow['jobs']['build']['steps']
                       if step.get('name') == 'Compile device firmware')
        self.assertLess(command.index('make buildinfo'), command.index('make package/compile'))
        self.assertLess(command.index('make package/compile'), command.index('make -j1 V=s'))
        self.assertIn('for metadata in config feeds version; do', command)
        self.assertIn('test -s "bin/targets/mediatek/filogic/${metadata}.buildinfo"', command)


if __name__ == '__main__':
    unittest.main()
