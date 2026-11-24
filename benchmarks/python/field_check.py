"""Static scene (truth: zero velocity): how much velocity the session's fields show.
usage: field_check.py SESSION_DIR ...  → per session: median |mean velocity| and median temporal std over valid cells (px/s),
and the RMS of instantaneous PIV displacements per pair (px) from piv_vectors.csv."""
import sys, glob
import numpy as np, pandas as pd
for d in sys.argv[1:]:
    s = glob.glob(f"{d}/*/")[0]
    m = pd.read_csv(s + "mean_field.csv")
    m = m[m.valid == 1]
    sp = np.hypot(m.mean_u_px_s, m.mean_v_px_s)
    sd = np.sqrt((m.std_u_px_s ** 2 + m.std_v_px_s ** 2) / 2)
    out = f"{d:28s} mean-field |u| median {sp.median():6.3f} px/s, p95 {sp.quantile(.95):6.2f} | temporal std median {sd.median():6.2f} px/s"
    try:
        v = pd.read_csv(s + "piv_vectors.csv")
        cols = v.columns
        if 'dx_px' in cols:
            st = v[v.status == 0]
            out += f" | instantaneous RMS {np.sqrt((st.dx_px ** 2 + st.dy_px ** 2).mean() / 2):.3f} px/pair (median |d| {np.hypot(st.dx_px, st.dy_px).median():.3f})"
    except Exception as e:
        out += f" (vectors: {e})"
    print(out)
