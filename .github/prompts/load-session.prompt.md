---
description: "Load consul-mesh-poc session context from TODO.md and resume work at the next pending step"
argument-hint: "Optional: override or add context (e.g. 'step 3 failed, retry')"
agent: "agent"
---

Read [TODO.md](../../TODO.md) carefully and set the session context as follows:

1. **Identify the current state** — parse the step progress table and find:
   - The last ✅ completed step
   - The next ⬜ pending step

2. **Summarize the session state** — print a short status block like:
   ```
   === consul-mesh-poc Session Context ===
   Last completed : Step N — <title>
   Next to execute: Step M — <title>
   Pending steps  : M, M+1, ...
   ```

3. **Load the next step's details** — read the "Step Details" section in TODO.md for the next pending step and state:
   - Which files will be written
   - Any constraints or notes from the step definition

4. **Prompt the user to proceed** — end with:
   > Context loaded. Ready for Step M: <title>.  
   > Say **PROCEED** to begin, or give me any updated instructions first.

Do not begin writing any files yet. Only read and report state.
