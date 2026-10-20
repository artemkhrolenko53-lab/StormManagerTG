from dotenv import load_dotenv
import os

print("Loading .env...")
loaded = load_dotenv(".env")
print(f"load_dotenv returned: {loaded}")

db_url = os.getenv("DATABASE_URL")
print(f"DATABASE_URL from os.getenv: {db_url[:50] if db_url else 'None'}...")

if not db_url:
    print("DATABASE_URL is still None! Checking file existence...")
    import pathlib
    env_path = pathlib.Path(".env")
    print(f".env exists: {env_path.exists()}")
    if env_path.exists():
        print(f".env size: {env_path.stat().st_size} bytes")
        print(f".env content preview:")
        with open(".env", "r", encoding="utf-8") as f:
            lines = f.readlines()[:5]
            for line in lines:
                print(f"  {line.rstrip()}")
