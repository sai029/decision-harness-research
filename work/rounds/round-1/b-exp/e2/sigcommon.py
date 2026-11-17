import json,hashlib
from cryptography.hazmat.primitives.asymmetric.ed25519 import Ed25519PublicKey
def canon(cand_id,title,decision,rationale,decider,scope,confirmed_by,confirmed_at):
    return json.dumps([cand_id,title,decision,rationale,decider,scope,confirmed_by,confirmed_at],ensure_ascii=False,separators=(',',':')).encode('utf-8')
def make_verifier(registry):
    """registry: {approver_id: pubkey_hex}（DB の外=Git 管理のファイルから読む）"""
    def verify_confirmation(*a):
        *fields,sig=a
        try:
            pk=registry.get(fields[6])
            if not pk or not sig: return 0
            Ed25519PublicKey.from_public_bytes(bytes.fromhex(pk)).verify(bytes.fromhex(sig),canon(*fields))
            return 1
        except Exception: return 0
    return verify_confirmation
