import io, pdfplumber

def pdf_to_text(file_bytes: bytes) -> str:
    with pdfplumber.open(io.BytesIO(file_bytes)) as pdf:
        texts = [page.extract_text() or "" for page in pdf.pages]
    return "\n".join(texts).strip()
