"""Compatibility entry point; the wall regression now lives with the planner."""
from pathlib import Path
import runpy
runpy.run_path(str(Path(__file__).with_name('planner_regression.py')), run_name='__main__')
