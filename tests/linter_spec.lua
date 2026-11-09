local linter = require("pele_mermaid.linter")

-- 1. Unquoted parentheses in node labels
local invalid1 = [[flowchart LR
  Voice[Retool Voice (Twilio SDK)] --> Backend[Workforce Manager (CallStart)]
]]
local issues1 = linter.lint(invalid1)
assert(#issues1 >= 1, "linter must detect unquoted parentheses in node labels")

local res1 = linter.fix(invalid1)
assert(res1.changed == true)
assert(res1.fixed:match('Voice%["Retool Voice %(Twilio SDK%)"%]'))
assert(res1.fixed:match('Backend%["Workforce Manager %(CallStart%)"%]'))

-- 2. Unquoted special characters (paths, colons) in node labels
local invalid2 = [[flowchart TB
  A[POST /handle-call] --> B[Host: 127.0.0.1]
]]
local res2 = linter.fix(invalid2)
assert(res2.fixed:find('A["POST /handle-call"]', 1, true), "must quote path in label")
assert(res2.fixed:find('B["Host: 127.0.0.1"]', 1, true), "must quote colon in label")

-- 3. Trailing semicolons and single-dash arrows
local invalid3 = [[flowchart LR
  A -> B;
]]
local res3 = linter.fix(invalid3)
assert(res3.changed == true)
assert(not res3.fixed:match(";"), "trailing semicolons should be removed")
assert(res3.fixed:match("A %-%-> B"), "single dash arrow should be normalized to -->")

-- 4. Clean source remains unchanged
local clean = [[flowchart LR
  A["Clean Node"] --> B["Another Node"]
]]
local clean_res = linter.fix(clean)
assert(clean_res.changed == false)
assert(clean_res.fixed == clean)

for _, preserved in ipairs({
  [=[flowchart LR
A["Say \"X -> Y;\""] --> B]=],
  [=[flowchart LR
A["C:\\tools\\file -> https://example.test/a:b;"] --> B]=],
  [=[flowchart LR
A["unfinished \"quote -> label;]=],
  [=[sequenceDiagram
A->B: valid synchronous arrow]=],
  [=[flowchart LR
%% A -> B;
A ----> B]=],
}) do
  local result = linter.fix(preserved)
  assert(result.fixed == preserved and not result.changed, "valid/quoted/unsupported syntax must remain byte-identical")
end
local mixed = linter.fix([=[flowchart LR
A["Say \"X -> Y\""] -> B]=])
assert(mixed.fixed == [=[flowchart LR
A["Say \"X -> Y\""] --> B]=], "repair outside quotes without changing escaped quoted content")
