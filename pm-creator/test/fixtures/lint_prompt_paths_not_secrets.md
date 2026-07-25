# Dispatch: audit an adapter contract

## Prompt (paste below this line)

Read the transition-state adapter implementation at
`/home/alon/Code/ARC/arc/job/adapters/ts/linear.py` and its support package at
`/home/alon/Code/ARC/arc/job/adapters/ts/linear_utils/`.

Cross-check the registration table in
`/home/alon/Code/ARC/arc/job/adapters/ts/common.py` against the enum entry in
`/home/alon/Code/ARC/arc/job/adapter.py`, then trace the verification path
through `/home/alon/Code/ARC/arc/checks/nmd.py`.

Ground truth for a completed run lives at
`/home/alon/runs/ARC/poly_101/R1/calcs/TSs/TS0/geometry/freq.out`.

None of the above is a credential; they are the grounded absolute paths that
§8 rule 4 requires every dispatch prompt to carry.

For contrast, this one IS a secret shape and must still warn (an obviously
fake 44-character base64 blob with no path structure):

    aGVsbG8gd29ybGQgdGhpcyBpcyBub3QgYSBwYXRoIGF0IGFsbA==
