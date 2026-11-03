# Glossary

**Rewrite**: The mode used when text is selected. The model's output replaces exactly the selected text.

**Insert**: The mode used when nothing is selected. The model's output is placed at the cursor.

**Instruction**: What the user types into the floating prompt to tell the model what to do.

**Context**: The unchanged text around the selection (Rewrite) or the cursor (Insert), sent with the Instruction so the output fits its surroundings. _Avoid_: surrounding text, buffer.

**Cancel**: The user stopping a request that is still running. The buffer is left as it was, and a Cancel is not a failure. _Avoid_: abort.
