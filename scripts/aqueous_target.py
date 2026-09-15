"""Shared, immutable Aqueous integration target."""
import json
from pathlib import Path
ROOT=Path(__file__).resolve().parents[1]
TARGET=json.loads((ROOT/"scripts/aqueous-target.json").read_text())
REV=TARGET["revision"]
PREFIX=ROOT/TARGET["prefix"]
