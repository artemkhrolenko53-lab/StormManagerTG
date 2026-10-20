from dotenv import load_dotenv
load_dotenv()

from storm import db
from pathlib import Path

with db.connect() as conn:
    db.apply_schema(conn, Path('schema.sql'))
    print('Schema applied!')
