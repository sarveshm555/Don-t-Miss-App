import hashlib
import hmac
import secrets

# Standard configuration: 100,000 iterations of SHA-256
PBKDF2_ITERATIONS = 100_000
SALT_BYTES = 16

def hash_password(password: str) -> str:
    """Hash a plaintext password using salt and PBKDF2-HMAC-SHA256."""
    salt = secrets.token_hex(SALT_BYTES)
    hash_bytes = hashlib.pbkdf2_hmac(
        hash_name="sha256",
        password=password.encode("utf-8"),
        salt=salt.encode("utf-8"),
        iterations=PBKDF2_ITERATIONS,
    )
    return f"pbkdf2:sha256:{PBKDF2_ITERATIONS}${salt}${hash_bytes.hex()}"

def verify_password(password: str, hashed_password: str) -> bool:
    """Verify a plaintext password against a stored PBKDF2-HMAC-SHA256 hash."""
    try:
        parts = hashed_password.split("$")
        if len(parts) != 3:
            return False
        
        algorithm_meta, salt, expected_hash = parts
        _, _, iterations_str = algorithm_meta.split(":")
        iterations = int(iterations_str)

        calculated_bytes = hashlib.pbkdf2_hmac(
            hash_name="sha256",
            password=password.encode("utf-8"),
            salt=salt.encode("utf-8"),
            iterations=iterations,
        )
        return hmac.compare_digest(calculated_bytes.hex(), expected_hash)
    except Exception:
        return False
