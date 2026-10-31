# lib/declaration.jq — validates a declaration against a schema in ADR-038 D1's
# subset, until `module-manager declaration validate` exists. Prints one line
# per finding: "<path>: <rule>". No output = valid.
#
# Usage: jq -r --slurpfile s schema.json -f declaration.jq declaration.json

def where($p):
  if ($p | length) == 0 then "(root)"
  else reduce $p[] as $k (""; if ($k | type) == "number" then . + "[\($k)]" elif . == "" then $k else . + "." + $k end)
  end;

def jtype:
  if type == "number" then (if . == floor then "integer" else "number" end) else type end;

def check($s; $p):
  . as $v
  | ($v | jtype) as $t
  | if ($s.type // null) != null
       and $t != $s.type
       and ($s.type != "number" or $t != "integer") then
      "\(where($p)): expected \($s.type), got \($t)"
    else
      (if $s.enum and (($s.enum | index([$v])) == null) then "\(where($p)): not one of \($s.enum | map(tostring) | join(", "))" else empty end),
      (if ($s | has("const")) and $v != $s.const then "\(where($p)): must be \($s.const | tostring)" else empty end),
      (if $t == "string" then
         (if $s.pattern and ($v | test($s.pattern) | not) then "\(where($p)): does not match \($s.pattern)" else empty end),
         (if $s.minLength and ($v | length) < $s.minLength then "\(where($p)): shorter than \($s.minLength)" else empty end),
         (if $s.maxLength and ($v | length) > $s.maxLength then "\(where($p)): longer than \($s.maxLength)" else empty end)
       else empty end),
      (if $t == "integer" or $t == "number" then
         (if ($s | has("minimum")) and $v < $s.minimum then "\(where($p)): below \($s.minimum)" else empty end),
         (if ($s | has("maximum")) and $v > $s.maximum then "\(where($p)): above \($s.maximum)" else empty end)
       else empty end),
      (if $t == "array" then
         (if $s.minItems and ($v | length) < $s.minItems then "\(where($p)): fewer than \($s.minItems) items" else empty end),
         (if $s.maxItems and ($v | length) > $s.maxItems then "\(where($p)): more than \($s.maxItems) items" else empty end),
         (if $s.uniqueItems and ($v | length) != ($v | unique | length) then "\(where($p)): items are not unique" else empty end),
         (if $s.key then
            ([$v[] | .[$s.key]] | group_by(.) | map(select(length > 1) | .[0])[]
             | "\(where($p)): duplicate \($s.key) '\(.)'")
          else empty end),
         (if $s.items then ($v | to_entries[] | .key as $i | .value | check($s.items; $p + [$i])) else empty end)
       else empty end),
      (if $t == "object" then
         (($s.required // [])[] as $k | select(($v | has($k)) | not) | "\(where($p + [$k])): required"),
         ($v | keys_unsorted[] as $k | select((($s.properties // {}) | has($k)) | not)
            | select(($s.additionalProperties // false) == false)
            | "\(where($p + [$k])): not allowed here"),
         ($v | to_entries[] | .key as $k | select(($s.properties // {}) | has($k))
            | .value | check($s.properties[$k]; $p + [$k]))
       else empty end)
    end;

check($s[0]; [])
