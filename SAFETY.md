# REDnet: what's protected, what isn't, and how to stay safe

A plain-language guide for everyone who uses REDnet. No technical background needed. If you read only
one section, read **"The short version."**

---

## The short version

REDnet keeps **the words inside your messages secret**, even from the people who run the server. You can
sign up **without giving your real name, phone number, or email.** And if the server is ever seized, the
messages stored on it stay **scrambled and unreadable.**

But no app can do everything. REDnet **cannot**:

- hide the **fact** that you're using an encrypted chat app,
- protect you if your **phone or laptop is unlocked, stolen, or infected with spyware,**
- protect you from a person you're talking to who is an **informant** or whose device is compromised.

So the three habits that keep you safe:

1. **Guard your device** like it's the key to everything. It is.
2. **Match what you say to the room's safety level** (the banner at the top of each room).
3. When something would be **catastrophic if read by the wrong person, say it in person.** Not in any app.

---

## What REDnet protects

**1. The words in your messages.**
Your messages are sealed with **end-to-end encryption.** Think of every message as a letter in an envelope
that _only you and the person you're writing to_ have the key to open. The server passes the envelope along
but cannot open it. Neither can the people who run the server, nor someone who seizes it.

**2. Who you are, when you sign up.**
REDnet does **not** ask for your phone number, email, or real name. You join with a **one-time invite code**
from someone already trusted in your community. There is no "phone number = your identity" link the way there
is with most apps. The server doesn't hold that information, so it can't be taken from it.

**3. The server, if it's seized.**
REDnet is built on the assumption that **the server will eventually be taken.** So it's designed to hold as
little as possible: messages are stored scrambled (unreadable without the keys, which live only on people's
devices), and the small records of _who connected and when_ are **kept tiny and erased fast.**
A seized server is meant to be a disappointment to whoever seizes it.

---

## What REDnet does NOT protect

Believing you're protected when you're not is more dangerous than knowing your limits.

**Your device.**
Encryption protects messages _in transit and on the server._ It does **nothing** if someone has your unlocked
phone in their hand, or has infected it with spyware (like Pegasus). On your own screen, your messages are
readable (that's the point), so anyone who controls your device reads what you read. **Your device security
is your job, and it's the weakest point.** Lock it with a strong passcode, keep it updated, don't tap
suspicious links, and have a plan if it might be seized.

**The fact that you're using an encrypted app.**
Someone who can watch your internet connection (an internet provider, a border checkpoint, a state telecom)
often **can't read your messages but _can_ tell you're using encrypted chat.** In some places, _that alone_
draws attention. REDnet can't hide this. If merely being seen to use a secure tool is dangerous where you
are, that's a Tier-3 situation (see below). Handle it offline.

**Some of "who talked to whom, and when."**
The server needs to route messages, so it sees limited patterns: who's online, who's in which room.
REDnet keeps this **minimal and short-lived**, but it is **not zero.** A server seized _right now_ could
reveal a little recent activity. Treat _who you're connected to_ as better-hidden than your words are
hidden, but not perfectly hidden.

Specifically: the server retains a record of recent client IP addresses for up to **one day** (not
indefinitely, but not zero). An hourly scrub job removes older records from the authentication layer.
This means a server seized _right now_ could reveal which IP addresses connected in the past day.
If hiding your IP address from a seized server matters to you, connect through **Tor** (the Tor
Browser or Orbot on mobile) or a trusted VPN.

**The other person.**
Encryption protects the pipe between you, not the people at the ends. If the person you message is an
informant, or screenshots your chat, or has a compromised phone, **your words to them are exposed.** No
encryption can prevent that. Trust people, not just tools.

**Notifications on your phone.**
If your phone _pops up_ "new message," then Apple or Google (and a relay service) learn that _something
arrived and when_. Never the contents, but the timing and pattern. For most people this is an acceptable
trade for convenience. For high-risk users it's a real leak: **turn notifications off**, or use the website
on a computer instead of the phone app.

**Web vs. mobile: the protections are not identical.**
The REDnet website (Element Web) suppresses typing indicators and read receipts. The **mobile app**
(Element X from the public app store) does not suppress these by default, because it runs stock code we
don't control. On mobile, other people in a room can see that you're typing and when you've read a
message. If this matters, change the setting in the mobile app (Settings → Notifications → Read
receipts), or use the website for sensitive conversations.

**Searching old messages.**
Because messages are encrypted, searching through old conversations works **only on the desktop app**
(Element Desktop or the website), where your device has stored the decrypted copies. The mobile app
cannot search encrypted message history. If you need to find something, use the website or desktop.
For must-find information, your community may pin important messages or keep a #reference room.

---

## A note about "online" status

Everyone on REDnet appears **offline** at all times. This is on purpose. The server does not track or
broadcast who is currently online. You will not see green dots. This means you can't tell at a glance
whether someone is available, but it also means no one can tell when _you_ are active.

---

## Safety levels: what's OK to say where

Every room shows a **banner** telling you its safety level. Match your words to it. The levels describe _what
stays secret if the worst happens_, not what topics are allowed. Only you know what's sensitive for you.

- **Tier 1, "The words are secret."** (This is most of REDnet.)
  Safe to assume: nobody can read your messages. _Not_ safe to assume: that the fact you talked to someone, or
  roughly when, is perfectly hidden. **Good for:** day-to-day coordination, planning, organizing.
  **Not for:** anything where _even knowing two people are in contact_ could get someone hurt.

- **Tier 2, "The words _and_ who-you-are are secret."** (A separate, higher-security tool your community may
  link to.) Use it when hiding the _connection between people_ matters, not just the content.

- **Tier 3, "Nothing is written down anywhere."**
  In person, no phones in the room. The only way to protect something whose _existence_ is dangerous. When in
  doubt, this is always the safest choice.

**Rule of thumb:** if you catch yourself thinking "I really hope no one ever sees this," it belongs a tier
higher than wherever you're typing it.

---

## Your part of the job

- **Lock and update your device.** A strong passcode (not a 4-digit PIN), automatic screen lock, latest
  software. This matters more than any feature REDnet has.
- **Protect your recovery passphrase** (see below).
- **Use your own invite code; don't pass your account around.** Each person should join with their own code so
  the community can tell who's who and cut off a compromised account.
- **Check that contacts are verified.** The app shows when a person's identity is confirmed (a green shield or
  check). If it warns you a contact is "unverified" or "changed," stop and ask them out-of-band before sharing
  anything sensitive. That warning is how an impostor gets caught.
- **Match the tier.** Take sensitive things to a higher tier or in person.
- **Assume the worst is possible.** Don't write what would be catastrophic if your device were seized or your
  contact turned. The app is a tool, not a guarantee.

---

## Your recovery passphrase

When you set up REDnet, you get a **recovery passphrase** (a short list of words). This is how you get your
account and message history back if you lose your phone.

- **Write it down and store it somewhere safe and separate from your device.** Not a note on the same phone.
- **No one can reset it for you.** Not REDnet, not your organizers, not us. That's on purpose: if _we_ could
  reset it, so could anyone who seizes the server or pressures us. The flip side: **if you lose both your
  device and your passphrase, your old messages are gone for good.** That's the safe failure, by design.

---

## The honest bottom line

REDnet makes things **much harder, not impossible,** for a powerful, well-funded adversary. It
protects your words and your sign-up identity. It **cannot** protect a hacked or seized device,
**cannot** hide that you're using it, and **cannot** save you from a bad actor you choose to trust.

One more honesty: this software has **not yet had a professional outside security audit** (see
`SECURITY-REVIEW.md`). It's built and self-tested, but for the **highest-stakes situations, where a
mistake means prison or worse, do not bet your life on any app.** Use Tier 3: in person, no devices.

Used with these habits, REDnet is a strong shield. Used carelessly (a hacked phone, the wrong words in the
wrong room, an untrustworthy contact), no app can save you. The tool does its part. These habits are yours.
