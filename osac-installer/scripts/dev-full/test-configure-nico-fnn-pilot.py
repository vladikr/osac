#!/usr/bin/env python3
"""Exercise the Launchpad binding upgrade using the old subnet-scoped configuration."""
import importlib.util
import json
from pathlib import Path
import unittest
from unittest.mock import patch

import yaml

spec = importlib.util.spec_from_file_location("pilot", Path(__file__).with_name("configure-nico-fnn-pilot.py"))
pilot = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pilot)


class PilotBindingTests(unittest.TestCase):
    def test_existing_binding_upgrades_once_and_preserves_other_entries(self):
        legacy = {"osacTenantID": "tenant1", "osacSubnetID": "01a21a44-015e-7849-9e5a-634c000d0d48",
                  "credentialIDs": [3, 4]}
        other = {"osacTenantID": "tenant2", "osacBareMetalInstanceTypeID": "other", "credentialIDs": [9]}
        other_os = {"diskImageID": "other", "nicoOperatingSystemID": "other-os"}
        contents = {"version": 2, "bindings": [legacy, other], "operatingSystems": [other_os]}
        cm = {"metadata": {"resourceVersion": "27"}, "data": {"bindings.yaml": yaml.safe_dump(contents)}}
        with patch.object(pilot, "k8s_object", return_value=cm), patch.object(pilot, "kubectl") as kube:
            pilot.configure_binding([3, 5])
            update = json.loads(kube.call_args.args[-1])
            self.assertEqual(update["metadata"]["resourceVersion"], "27")
            cm["data"].update(update["data"])
            updated = yaml.safe_load(cm["data"]["bindings.yaml"])
            old, preserved, binding = updated["bindings"]
            self.assertEqual(old, legacy)
            self.assertNotIn("osacBareMetalInstanceTypeID", binding)
            self.assertEqual(preserved, other)
            self.assertIn(other_os, updated["operatingSystems"])
            self.assertNotIn("osacSubnetID", binding)
            self.assertEqual(binding["placementTargetID"], "nico-gb300-fnn-nvl72")
            self.assertEqual(binding["credentialIDs"], [3, 5])
            pilot.configure_binding([3, 5])
            kube.assert_called_once()


if __name__ == "__main__":
    unittest.main()
