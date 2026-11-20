# Pull a benchmark set out of a (copied) Wispr Flow DB: text pairs + WAV clips. Stays local.
import json, sqlite3, sys, os, shutil, tempfile
src = os.path.expanduser("~/Library/Application Support/Wispr Flow/flow.sqlite")
out = os.path.join(os.path.dirname(__file__), "data")
tmp = tempfile.mkdtemp()
for ext in ("", "-wal", "-shm"):  # copy so we never touch the live DB
    if os.path.exists(src + ext): shutil.copy(src + ext, os.path.join(tmp, "flow.sqlite" + ext))
db = sqlite3.connect(os.path.join(tmp, "flow.sqlite"))
rows = db.execute("""select transcriptEntityId, detectedLanguage, app, asrText, formattedText, editedText,
                     duration, audio from History
                     where asrText is not null and formattedText is not null order by timestamp""").fetchall()
n_audio = 0
with open(os.path.join(out, "pairs.jsonl"), "w") as f:
    for id, lang, app, asr, fmt, edited, dur, audio in rows:
        has = bool(audio) and audio[:4] == b"RIFF"
        if has:
            open(os.path.join(out, "clips", id + ".wav"), "wb").write(audio); n_audio += 1
        f.write(json.dumps(dict(id=id, lang=lang, app=app, asr=asr, formatted=fmt, edited=edited,
                                duration=dur, audio=has), ensure_ascii=False) + "\n")
shutil.rmtree(tmp)
print(len(rows), "pairs,", n_audio, "clips")
