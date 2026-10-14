# fetch-ticket.sh — puts the ticket a pull request claims to implement in front
# of the reviewer, as a FILE it reads, never as prompt text.
#
# Two properties matter more than the fetching:
#
#   1. It ALWAYS writes the output file. base.md refers to that path in static
#      prose, so a missing file would send the reviewer looking for something
#      that is not there — and a `Read` that fails costs a turn, which is the
#      budget problem this repository has just spent a day measuring. No ticket,
#      no credential, network down: still a file, saying which.
#   2. It never fails the job and never prints the credential.
#
# The ticket body is written by whoever files tickets, so it is material under
# review (base.md rule 7), not instruction. The file says so in its own header.

_out() { printf '%s' "$TESTTMP/ticket.md"; }
_fetch() { "$SCRIPTS/fetch-ticket.sh" --out "$(_out)" "$@"; }
_body() { cat "$(_out)"; }

# --- identifying the ticket --------------------------------------------------

it "takes the ticket key from the pull request title"
assert_contains "KOR-238" "KOR-238 found in a title" -- \
  _fetch --title "KOR-238 : on se connecte par un écran" --branch "feature/login" \
         --response-file "$FIXTURES/linear-ok.json"

it "falls back to the branch name, case-insensitively"
assert_contains "KOR-62" "kor-62 in a branch is found and upcased" -- \
  _fetch --title "Rework the login screen" --branch "fjday/kor-62-isolation" \
         --response-file "$FIXTURES/linear-ok.json"

it "prefers the title over the branch when both carry a key"
_fetch --title "KOR-100 do the thing" --branch "user/kor-999-other" \
       --response-file "$FIXTURES/linear-ok.json" >/dev/null 2>&1
assert_equal "0" "$(_body | grep -c 'KOR-999')" "the branch key is not used when the title has one"

# --- every path still writes the file ----------------------------------------

it "writes a file when no ticket key is present anywhere"
assert_status 0 "exits 0 with no key" -- _fetch --title "Bump deps" --branch "chore/bump"
assert_contains "No Linear ticket" "says there is no ticket" -- _body

it "writes a file when the credential is absent"
assert_status 0 "exits 0 with no credential" -- \
  env -u LINEAR_API_KEY "$SCRIPTS/fetch-ticket.sh" --out "$(_out)" --title "KOR-238 x" --branch main
assert_contains "No Linear ticket" "says why it has no ticket" -- _body

it "writes a file when the API returns an error"
assert_status 0 "exits 0 on an API error" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-error.json"
assert_contains "could not be read" "says the ticket could not be read" -- _body

it "writes a file when the response is not the shape expected"
assert_status 0 "exits 0 on a malformed response" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/malformed.json"

it "writes a file when the ticket does not exist"
assert_status 0 "exits 0 when the ticket is absent" -- \
  _fetch --title "KOR-999 x" --branch main --response-file "$FIXTURES/linear-empty.json"
assert_contains "No Linear ticket" "an absent ticket reads like no ticket" -- _body

# --- the content the reviewer sees -------------------------------------------

it "marks the ticket as data, not as instruction"
_fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-ok.json" >/dev/null 2>&1
assert_contains "rule 7" "the header cites the data-not-instruction rule" -- _body
assert_contains "material under review" "the header says what this text is" -- _body

it "carries the parts of the ticket a reviewer needs"
assert_contains "Sign in from a screen" "the title is present" -- _body
assert_contains "three states" "the description is present" -- _body
assert_contains "In Progress" "the state is present" -- _body

it "never writes the credential into the file"
assert_not_contains "lin_api" "no credential in the output" -- _body

it "never prints the credential to the log"
assert_not_contains "lin_api" "no credential on stdout or stderr" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-ok.json"

it "caps a very long description"
_fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-huge.json" >/dev/null 2>&1
_size="$(wc -c < "$(_out)")"
if [ "$_size" -lt 40000 ]; then
  _ok "a 200 KB description is capped (${_size} bytes)"
else
  _bad "a 200 KB description is capped" "file is ${_size} bytes"
fi
assert_contains "truncated" "the truncation is disclosed" -- _body

# --- tickets withheld by label -----------------------------------------------
# The team's data policy: a ticket labelled retour-client or attente-client can
# quote a real client, and its text does not go to the model provider. The file
# is still written, and says only that the ticket is withheld and why.

it "withholds a ticket labelled retour-client"
assert_status 0 "exits 0 on a withheld ticket" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-retour-client.json"
assert_contains "withheld" "the file says the ticket is withheld" -- _body
assert_contains "retour-client" "the file names the label that withheld it" -- _body
assert_contains "KOR-238" "the file keeps the identifier" -- _body
assert_not_contains "Fix the export" "the title is not written" -- _body
assert_not_contains "Client Dupont" "the description is not written" -- _body
assert_not_contains "In Progress" "the state is not written" -- _body
assert_contains "KOR-238 withheld (label retour-client)" "the log says which label withheld it" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-retour-client.json"

it "withholds attente-client whatever its case and surrounding spaces"
_fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-attente-client.json" >/dev/null 2>&1
assert_contains "withheld" "the file says the ticket is withheld" -- _body
assert_contains "attente-client" "the file names the label that withheld it" -- _body
assert_not_contains "Client Martin" "the description is not written" -- _body

it "still sends a ticket whose labels are read and none is withheld"
_fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-ok.json" >/dev/null 2>&1
assert_not_contains "withheld" "a ticket with a neutral label is not withheld" -- _body
assert_contains "Sign in from a screen" "its title is sent" -- _body
assert_contains "three states" "its description is sent" -- _body

it "withholds a ticket whose labels cannot be read"
assert_status 0 "exits 0 when the labels are absent" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-no-labels.json"
assert_contains "withheld" "a ticket without a labels field is withheld" -- _body
assert_contains "labels unreadable" "the file says why" -- _body
assert_not_contains "three states" "the description is not written" -- _body

it "turns the filter off with an empty --withhold-labels"
_fetch --title "KOR-238 x" --branch main --withhold-labels "" \
       --response-file "$FIXTURES/linear-retour-client.json" >/dev/null 2>&1
assert_not_contains "withheld" "a retour-client ticket is sent" -- _body
assert_contains "Client Dupont" "its description is sent" -- _body

it "withholds exactly the labels --withhold-labels names"
_fetch --title "KOR-238 x" --branch main --withhold-labels "autre" \
       --response-file "$FIXTURES/linear-retour-client.json" >/dev/null 2>&1
assert_contains "Fix the export" "retour-client is sent once the list leaves it out" -- _body
_fetch --title "KOR-238 x" --branch main --withhold-labels " Bogus , AUTRE " \
       --response-file "$FIXTURES/linear-ok.json" >/dev/null 2>&1
assert_contains "withheld" "a ticket labelled autre is withheld" -- _body
assert_contains "label autre" "the file names the configured label" -- _body
assert_not_contains "three states" "its description is not written" -- _body

it "withholds a ticket whose labels run past the page read"
_fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-labels-next-page.json" >/dev/null 2>&1
assert_contains "labels unreadable" "a second page of labels withholds the ticket" -- _body
assert_not_contains "three states" "the description is not written" -- _body

it "withholds a ticket whose label list does not say there is no further page"
_fetch --title "KOR-238 x" --branch main --withhold-labels "autre-x" \
       --response-file "$FIXTURES/linear-attente-client.json" >/dev/null 2>&1
assert_contains "labels unreadable" "an absent pageInfo withholds the ticket" -- _body
assert_not_contains "Client Martin" "the description is not written" -- _body

it "withholds a ticket with a label that has no name"
_fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-label-no-name.json" >/dev/null 2>&1
assert_contains "labels unreadable" "a nameless label withholds the ticket" -- _body
assert_not_contains "three states" "the description is not written" -- _body

it "prints nothing of a withheld ticket to the log"
assert_not_contains "Client Dupont" "no description on stdout or stderr" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-retour-client.json"
assert_not_contains "Fix the export" "no title on stdout or stderr" -- \
  _fetch --title "KOR-238 x" --branch main --response-file "$FIXTURES/linear-retour-client.json"
