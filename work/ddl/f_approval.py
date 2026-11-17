"""担当F: 承認の署名・検証 (E2)。

- 承認者側: sign(private_key, message)  -- ssh-keygen -Y sign (Git の SSH 署名と同じ仕組み)
- 検証側  : verify(allowed_signers, principal, message, sig) -- 公開鍵だけで検証できる
- DB 側   : register(conn, allowed_signers) で SQL 関数 entry_hash / verify_sig を登録
- 読み出し側: verified_effective(conn, allowed_signers) は DB の status を信用せず、
  承認ごとに署名を再検証して注入してよい id だけを返す (第2層。DB を直接書き換えられても効く)
鍵はテストが実行時に一時ディレクトリへ生成した使い捨て。リポジトリには置かない。
"""
import hashlib, os, subprocess, tempfile

NS = "decision-approval"


def entry_hash(cls, topic, choice, stmt, scope, decider, strength, vf, vu):
    s = "\x1f".join("" if x is None else str(x) for x in (cls, topic, choice, stmt, scope, decider, strength, vf, vu))
    return hashlib.sha256(s.encode("utf-8")).hexdigest()


def gen_key(dirpath, name):
    path = os.path.join(dirpath, name)
    subprocess.run(["ssh-keygen", "-q", "-t", "ed25519", "-N", "", "-C", name, "-f", path], check=True)
    pub = open(path + ".pub", encoding="utf-8").read().split()
    return path, f"{pub[0]} {pub[1]}"          # (秘密鍵パス, 'ssh-ed25519 AAAA...')


def write_allowed_signers(path, principal_to_pub):
    with open(path, "w", encoding="utf-8", newline="\n") as f:
        for p, pub in principal_to_pub.items():
            f.write(f'{p} namespaces="{NS}" {pub}\n')


def sign(private_key, message):
    r = subprocess.run(["ssh-keygen", "-Y", "sign", "-f", private_key, "-n", NS],
                       input=message.encode("utf-8"), capture_output=True, check=True)
    return r.stdout.decode("utf-8")


def verify(allowed_signers, principal, message, sig):
    if not sig or not principal:
        return False
    with tempfile.TemporaryDirectory() as d:
        sp = os.path.join(d, "s.sig")
        with open(sp, "w", encoding="utf-8", newline="\n") as f:
            f.write(sig)
        r = subprocess.run(["ssh-keygen", "-Y", "verify", "-f", allowed_signers, "-I", principal, "-n", NS, "-s", sp],
                           input=message.encode("utf-8"), capture_output=True)
        return r.returncode == 0


def register(conn, allowed_signers):
    conn.create_function("entry_hash", 9, entry_hash, deterministic=True)
    conn.create_function("verify_sig", 3, lambda p, m, s: 1 if verify(allowed_signers, p, m, s) else 0)


def approval_message(entry_id, h, epoch, approver, approved_at):
    return f"entry|{entry_id}|{h}|{epoch}|{approver}|{approved_at}"


def verified_effective(conn, allowed_signers, task_scope):
    """読み出し時の再検証。v_effective_by_scope の各行について、現在の内容ハッシュ・epoch に一致する
    approval 行の署名を公開鍵で確かめ、通ったものだけ返す。"""
    ok = []
    for (eid, cls, topic, choice, stmt, scope, decider, strength, vf, vu, epoch) in conn.execute(
            "SELECT id,class_code,topic_key,choice,statement,scope,decider_alias,strength,valid_from,valid_until,epoch FROM v_effective_by_scope WHERE task_scope=?", (task_scope,)):
        h = entry_hash(cls, topic, choice, stmt, scope, decider, strength, vf, vu)
        for (aid, ah, aep, who, at, sig) in conn.execute(
                "SELECT id,entry_hash,epoch,approver_alias,approved_at,sig FROM approval WHERE entry_id=?", (eid,)):
            if ah == h and aep == epoch and verify(allowed_signers, who, approval_message(eid, h, aep, who, at), sig):
                ok.append(eid)
                break
    return ok
