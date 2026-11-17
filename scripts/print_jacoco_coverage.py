# Copyright 2026 Google LLC
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#      http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.
"""Prints per-module line coverage percentages from JaCoCo XML reports."""

import sys
import xml.etree.ElementTree as ET

for path in sys.argv[1:]:
  line = ET.parse(path).getroot().find("counter[@type='LINE']")
  if line is None:
    continue
  covered = int(line.get("covered", 0))
  missed = int(line.get("missed", 0))
  total = covered + missed
  percent = 100 * covered / total if total else 0
  module = path.split("target/")[0].rstrip("/") or "."
  print(f"{module}: {percent:.1f}% of {total} lines")
