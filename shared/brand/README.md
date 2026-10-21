# Brand asset generator

Use CPython 3.11 in a virtual environment. The runtime dependency lock includes hashes for universal wheels and CPython 3.11 wheels on macOS ARM64/x86-64 and Windows x86-64. Cairo must be provided by the operating system.

From the repository root:

```sh
python3.11 -m pip install --require-hashes --only-binary=:all: -r shared/brand/requirements.lock
cd shared/brand
python3.11 generate-brand.py
```

Hashes come from the versioned PyPI release metadata, including [CairoSVG 2.9.1](https://pypi.org/project/CairoSVG/2.9.1/#files), [cffi 2.1.1](https://pypi.org/project/cffi/2.1.1/#files), and [Pillow 13.0.0](https://pypi.org/project/pillow/13.0.0/#files). Other Python versions/platforms fail closed until their reviewed wheel hashes are added. Update pins and hashes together; do not bypass hash checking.
