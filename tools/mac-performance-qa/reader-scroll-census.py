#!/usr/bin/env python3
"""Count reader scroll controllers and retained row ranges without running the UI."""
import pathlib
import re
import sys
for name in sys.argv[1:]:
    text = pathlib.Path(name).read_text()
    print(f"{name}: lazy_stacks={len(re.findall(r'LazyVStack\(', text))} "
          f"position_bindings={len(re.findall(r'\.scrollPosition\(', text))} "
          f"proxy_commands={len(re.findall(r'proxy\.scrollTo\(', text))} "
          f"bottom_feedback={len(re.findall(r'onPreferenceChange\(BottomOffsetKey', text))}")
