"""Where this repository's Claude calls get their credentials, and how they ask.

No API key exists anywhere. The runner mints a GitHub OIDC token and Anthropic
exchanges it under a federation rule pinned to this repository and branch, so
the only thing that can spend these tokens is a workflow in this repository.

The ids live here, in one file, because two copies of an id are two things that
can drift apart: the scout and the lab sweep both read them from this module.
"""
import json
import os
import urllib.parse
import urllib.request

FEDERATION = dict(
    federation_rule_id="fdrl_01QKt4B9nXuMiFwfXsK8fDgn",
    organization_id="5b81a33e-20db-4174-a4f6-b2b4a2ee5e4d",
    service_account_id="svac_01QYRK965GvQQP3PfxnPojcy",
    workspace_id="wrkspc_011m5s23CDKyf5tfBksDf2ht",
)


def github_oidc_token():
    url = os.environ["ACTIONS_ID_TOKEN_REQUEST_URL"] + "&audience=" + urllib.parse.quote("https://api.anthropic.com", safe="")
    req = urllib.request.Request(url, headers={"Authorization": "bearer " + os.environ["ACTIONS_ID_TOKEN_REQUEST_TOKEN"]})
    with urllib.request.urlopen(req, timeout=30) as r:
        return json.load(r)["value"]


def answer(client, **call):
    """One call, one text answer, or an exception that says why there is none.

    TWO THINGS EVERY CALLER HERE GOT WRONG. The lab sweep asked for 4000 tokens
    over 59 commits and got back usage saying out=4000 with not one text block
    in it: extended thinking is on by default for these models and produces
    nothing until it finishes, so the whole budget went into reasoning and the
    answer never started. Raised to 16000 it did the same. Sorting commit
    messages into three verdicts does not need it.

    And the report was written anyway, because the caller only ever read the
    text blocks and never asked whether there were any. An issue that looks
    like a verdict and is a blank is worse than no issue: it reads as "nothing
    here was worth doing". An empty answer raises; a truncated one says so in
    the text, where whoever reads the report will see it.
    """
    try:
        msg = client.messages.create(thinking={"type": "disabled"}, **call)
    except Exception as e:                      # a model that will not be told
        if "thinking" not in str(e).lower():
            raise
        msg = client.messages.create(**call)
    text = "".join(getattr(b, "text", "") for b in msg.content).strip()
    if not text:
        raise RuntimeError("the model returned no text (stop_reason=%s, out=%d tokens)"
                           % (msg.stop_reason, msg.usage.output_tokens))
    if msg.stop_reason == "max_tokens":
        text += "\n\n*(cut off at the token ceiling: what follows the last section above was not assessed.)*"
    return text, msg
