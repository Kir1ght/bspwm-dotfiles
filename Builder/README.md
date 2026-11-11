# Builder

`Builder/install.py` — интерактивная обёртка над `../install.sh`.

Логика установки живёт в `install.sh` (его проще читать и запускать повторно),
а `Builder/` оставлен как удобный интерактивный вход:

```bash
python3 Builder/install.py
python3 Builder/install.py --yes
```

`packages.py` содержит те же группы пакетов, что и `install.sh`, — для
справки и будущих изменений. Если меняете список пакетов, меняйте оба файла.
