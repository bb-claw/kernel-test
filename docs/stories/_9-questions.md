# The 9 canonical questions

Ask and answer these before promoting a story from `draft` to `ready`.
A story with unanswered questions stays `draft`.

1. **Who** is the operator/user in this moment?
   Role, mental state, what else they're doing. If more than one person,
   split into separate stories.

2. **When** does the story fire?
   Trigger: event, state change, or cadence that activates this story.

3. **What** does success look like, concretely?
   Observable in operator-visible terms. Must be mechanically checkable.

4. **How urgent?**
   Critical / High / Normal / Low — pick one and justify.

5. **Happy path** — exact sequence of operator-visible steps?
   Include the command, flags, and expected exit code / output line.

6. **Edge cases / failure modes** that matter?
   At minimum: what happens when a dependency is absent or broken?

7. **Out of scope** — what could creep in but shouldn't?
   Name it explicitly. Silence invites scope creep.

8. **How do we know it's done?**
   Must be a Gherkin `Scenario` block. Vague acceptance criteria stay `draft`.

9. **What capabilities does this story deliver or extend?**
   List CAP ids. Mark NEW (not yet in CAPABILITIES.md) or EXT (extends existing).
   At least one CAP id required before promoting to `ready`.
