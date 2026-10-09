# -*- coding: utf-8 -*-
"""Extract text from the reference PDF plan file."""
import sys
import io

sys.stdout = io.TextIOWrapper(sys.stdout.buffer, encoding='utf-8')

from pypdf import PdfReader

PDF_PATH = r"c:\Users\Morse\Desktop\杨家贺-物理组-本科批-方案-内蒙古鸣远教育有限公司111.pdf"
OUT_PATH = r"c:\Users\Morse\Documents\trae_projects\gaobao\pdf_extracted.txt"

reader = PdfReader(PDF_PATH)
print(f"Total pages: {len(reader.pages)}")

all_text = []
for i, page in enumerate(reader.pages):
    try:
        text = page.extract_text() or ""
    except Exception as e:
        text = f"[page {i+1} extract error: {e}]"
    all_text.append(f"===== PAGE {i+1} =====\n{text}")

full = "\n".join(all_text)
with open(OUT_PATH, "w", encoding="utf-8") as f:
    f.write(full)

print(f"Extracted {len(full)} chars to {OUT_PATH}")
print("---- First 2000 chars ----")
print(full[:2000])
