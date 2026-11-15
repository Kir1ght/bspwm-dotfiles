# Builder

`Builder/install.py` is an interactive wrapper around `../install.sh`.

The installation logic lives in `install.sh` (it is easier to read and run
again), while `Builder/` is kept as a convenient interactive entry point:

```bash
python3 Builder/install.py
python3 Builder/install.py --yes
```

`packages.py` contains the same package groups as `install.sh` — for reference
and future changes. If you change the package list, update both files.
