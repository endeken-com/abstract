import base64
import unittest
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PrivateKey
from gateway import Admission


class AdmissionTests(unittest.TestCase):
    def setUp(self):
        self.now = 1_800_000_000
        self.admission = Admission(clock=lambda: self.now)

    def proof(self):
        key = Ed25519PrivateKey.generate()
        return {"key": key.public_key().public_bytes_raw().hex(), "timestamp": self.now,
                "signature": base64.b64encode(key.sign(f"abstract-relay-register-v1\n{self.now}".encode())).decode()}

    def test_requires_proof_and_expires(self):
        proof = self.proof()
        self.assertFalse(self.admission.allows(proof["key"]))
        self.admission.register(proof, "test")
        self.assertTrue(self.admission.allows(proof["key"]))
        self.now += 86401
        self.assertFalse(self.admission.allows(proof["key"]))
        with self.assertRaises(ValueError):
            self.admission.register(proof, "test")

    def test_rejects_another_keys_signature(self):
        first, second = self.proof(), self.proof()
        first["signature"] = second["signature"]
        with self.assertRaises(Exception):
            self.admission.register(first, "test")
        self.assertFalse(self.admission.allows(first["key"]))

    def test_quota_does_not_block_existing_device_renewal(self):
        proof = self.proof()
        self.admission.register(proof, "test")
        for _ in range(31):
            self.admission.register(self.proof(), "test")
        with self.assertRaises(OverflowError):
            self.admission.register(self.proof(), "test")
        self.admission.register(proof, "test")


if __name__ == "__main__":
    unittest.main()
