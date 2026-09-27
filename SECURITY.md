# Security

Reed runs on your Mac with two permissions that matter: it records from the
microphone, and it types into whatever app you are using. A defect in either
path is worth reporting, and this document says how.

## Reporting a vulnerability

**Use GitHub's private vulnerability reporting** — the **Security** tab of this
repository, then **Report a vulnerability**. That opens a private advisory
visible only to you and the maintainers.

**If that option is not offered, email `aantonyan@w20.ai` instead.** GitHub only
allows private vulnerability reporting on public repositories, so there is a
period around a repository first becoming public when the form does not exist
yet, and it can be disabled or unavailable at other times. The address works
whether or not the form does.

Either way: please do not open a public issue for a security problem, and
please do not post one in Discussions.

Reed is a small project. Expect a first reply within a week. If you have had no
response after two weeks, open a public issue saying only that you are waiting
on a security report — no details — so it is visible that one is outstanding.

What helps, in rough order of usefulness:

- the shortest reproduction you have, and the Reed version (**Settings → About**);
- your macOS version and Mac model;
- what an attacker would gain, and what they would need first — local access, a
  malicious app already running, a network position;
- any log excerpt that shows it. Reed's logs live in
  `~/Library/Application Support/Reed/` and may contain dictated text, so read
  before you attach.

## What is in scope

- **Audio capture.** Recording when Reed should not be, retaining audio it
  should have discarded, or exposing it to another process.
- **Text injection.** Reed types into the focused application
  (`Sources/Reed/Inject/TextInjector.swift`). Injecting into the wrong target,
  injecting content the user did not dictate, or being driven to inject by
  something other than the user.
- **Local data.** Transcripts, recordings kept by the developer-only local
  review tooling, and anything under Reed's Application Support directory being
  readable by, or leaking to, another user or process.
- **Updates.** Reed updates through Sparkle with EdDSA signature verification.
  Anything that installs an unsigned or substituted build is in scope.
- **The network boundary.** Reed is local-first; a network gate allows only a
  small allowlist. Anything that sends dictation content off the Mac, or widens
  that allowlist unexpectedly, is in scope.
- **Permission handling.** Anything that obtains microphone or Accessibility
  access without the user granting it, or that keeps it after revocation.

## What is not in scope

- **Requiring the permissions Reed asks for.** Reed needs microphone and
  Accessibility access to work; that a user who grants them can be recorded and
  typed for is the design, not a vulnerability.
- **An attacker who is already root, or already running code as your user.**
  At that point they do not need Reed.
- **The published Sparkle public key and the update feed URL.** These are
  public by design; they are not credentials and are not secrets. Reed has no
  analytics or crash reporting, so it carries no service identifiers.
- **Third-party services Reed talks to**, such as the model host. Report those
  to their owners.
- **Findings from automated scanners with no demonstrated impact.**

## What we will do

We will confirm receipt, tell you whether we consider it a vulnerability and
why, and keep you informed while we work. If we ship a fix we will say so in
the release, and we will credit you by whatever name you ask for, or not at all
if you prefer. We do not run a bounty.

If we decide something is not a vulnerability we will tell you that plainly,
with the reasoning, rather than letting the report go quiet.
