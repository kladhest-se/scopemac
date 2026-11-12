#!/usr/bin/env python3
# SPDX-License-Identifier: GPL-3.0-or-later
"""Read the application's single version source without invoking a compiler."""
import argparse
from pathlib import Path
import re


def version(root):
    text = (Path(root) / 'Sources/Version.swift').read_text()
    values = []
    for key, pattern in [('marketing', r'[0-9]+\.[0-9]+(?:\.[0-9]+)?'), ('build', r'[0-9]+')]:
        matches = re.findall(r'static let ' + key + r'\s*=\s*"(' + pattern + r')"', text)
        if len(matches) != 1:
            raise ValueError('Invalid or ambiguous app version: ' + key)
        values.append(matches[0])
    return tuple(values)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('field', choices=['marketing', 'build'])
    args = parser.parse_args()
    print(version(Path(__file__).resolve().parents[1])[args.field == 'build'])
