## What it does

<!-- In plain English, for someone who did not write it: what changes for the people who use this, and why. Two to five sentences. -->

## Try it on dev

<!-- The dev URL, the role to sign in as, and the clicks or requests that show it working, step by step. If it cannot be tried on dev, say why and how else to see it. -->

## Claude test prompt

<!-- Fill in the angle-bracket parts. A reviewer pastes this into Claude in Chrome to review the change and drive the test. The check refuses a prod host or anything credential-shaped. -->

```text
Review and test a pull request on a BeeSec dev environment, then report.

Rules: work only on <dev host, for example honeycomb-dev.beesec.co.uk>. Never open a prod host. Never type a password or token: I sign in myself, as <role>, when you ask. Report what you find and change nothing, so no commits, no comments and no settings.

1. Read the diff first: <PR URL>
2. Open <dev URL> and wait for me to sign in as <role>.
3. Test cases, each with its expected result:
   1. <step> -> expect <result>
   2. <step> -> expect <result>
4. Negative case: <for example, the same request as a lower role> -> expect <refused, with the status code>
5. Evidence: a screenshot of each result, or the network response with its status code and the key fields.
6. Verdict: pass or fail for each case, one line each, then anything else you noticed.
```

A Claude run is evidence, not approval. The second person still submits the approving review.

## How it was checked

<!-- The tests, the run or the request that shows it works. -->

## Review

- [ ] I have requested a reviewer on this page. Review alerts start after 4 working hours. Until both sections above are filled in, and while no reviewer is requested, alerts come to you.

Add `review-hold` to park this PR with no alerts, or `review-urgent` to bring the nudge forward to 1 working hour.
