package nixplan

import (
	"regexp"
	"strings"
)

// EvalCause is nix's root evaluation error, classified so a hold names its
// cause and whether it self-heals (plan-gate.sh eval_cause).
type EvalCause struct {
	Class  string // unfree | non-source | insecure | unsupported-platform | broken | refused | other
	Detail string
	Option string // innermost "while evaluating the option" frame above the root, if any
	Next   string
}

const evalWS = " \t\n\v\f\r"

var (
	reErrorLine    = regexp.MustCompile(`^[[:space:]]*error:`)
	reErrorPrefix  = regexp.MustCompile(`^[[:space:]]*error:[[:space:]]*`)
	reByName       = regexp.MustCompile(`/pkgs/by-name/[^/]+/([^/]+)/package\.nix`)
	reSourcePrefix = regexp.MustCompile(`/nix/store/[0-9a-z]{32}-source/`)
	reRefusal      = regexp.MustCompile(`^Refusing to evaluate package '([^']+)' in [^ ]+ because it `)
	reVersionTail  = regexp.MustCompile(`-[0-9].*$`)
)

const optionFrame = "while evaluating the option `"

// ClassifyEvalFailure picks the LAST `error:` line (nix prints the trace
// outermost-first). For a nixpkgs check-meta refusal, "via" is the nearest
// pkgs/by-name frame above the root: the package that pulled the refused one in.
func ClassifyEvalFailure(planText string) EvalCause {
	lines := strings.Split(planText, "\n")
	root := -1
	for i, l := range lines {
		if reErrorLine.MatchString(l) {
			root = i
		}
	}

	msg, option := "", ""
	var bynames []string
	if root >= 0 {
		// A bare "error:" or a "...:" header carries its message on the next lines.
		msg = strings.TrimRight(reErrorPrefix.ReplaceAllString(lines[root], ""), evalWS)
		j := root + 1
		for k := 0; k < 2 && (msg == "" || strings.HasSuffix(msg, ":")); k++ {
			for j < len(lines) && strings.Trim(lines[j], evalWS) == "" {
				j++
			}
			if j >= len(lines) {
				break
			}
			s := strings.Trim(lines[j], evalWS)
			j++
			if msg == "" {
				msg = s
			} else {
				msg += " " + s
			}
		}
		for i := root - 1; i >= 0; i-- {
			if idx := strings.LastIndex(lines[i], optionFrame); idx >= 0 {
				o := lines[i][idx+len(optionFrame):]
				if q := strings.IndexByte(o, '\''); q >= 0 {
					o = o[:q]
				}
				option = o
				break
			}
		}
		for i := root - 1; i >= 0; i-- {
			if m := reByName.FindStringSubmatch(lines[i]); m != nil {
				bynames = append(bynames, m[1])
			}
		}
	}
	msg = reSourcePrefix.ReplaceAllString(msg, "")

	m := reRefusal.FindStringSubmatch(msg)
	if m == nil {
		detail := msg
		if detail == "" {
			detail = "nix printed no error message"
		}
		return EvalCause{
			Class: "other", Detail: detail, Option: option,
			Next: "read the trace above - a removed or renamed nixpkgs attribute or option needs a repo change and never self-heals.",
		}
	}

	name := m[1]
	why := msg[strings.Index(msg, " because it ")+len(" because it "):]
	pname := reVersionTail.ReplaceAllString(name, "")
	via := ""
	for _, b := range bynames {
		if b != pname {
			via = b
			break
		}
	}
	c := EvalCause{Detail: name + " " + why, Option: option}
	if via != "" {
		c.Detail += ", via " + via
	}
	switch {
	case strings.HasPrefix(why, "has an unfree license"):
		c.Class = "unfree"
		c.Next = `needs a repo change - allowlist "` + pname + `" as unfree (Hydra never builds it, so baseline it too), or drop the package that pulls it in. Never self-heals.`
	case strings.HasPrefix(why, "contains elements not built from source"):
		c.Class = "non-source"
		c.Next = `needs a repo change - allow "` + pname + `" as non-source, or drop the package that pulls it in. Never self-heals.`
	case strings.HasPrefix(why, "is marked as insecure"):
		c.Class = "insecure"
		c.Next = `needs a repo change - permit "` + name + `" in permittedInsecurePackages, or drop the package that pulls it in; self-heals only once nixpkgs ships a fixed version.`
	case strings.HasPrefix(why, "is not available on the requested hostPlatform"):
		c.Class = "unsupported-platform"
		c.Next = "needs a repo change - drop or replace the package that pulls it in. Never self-heals."
	case strings.HasPrefix(why, "has problems:") && strings.Contains(why[len("has problems:"):], "- broken"):
		c.Class = "broken"
		c.Next = "hold - self-heals once nixpkgs fixes it; dropping the package that pulls it in unblocks sooner."
	default:
		c.Class = "refused"
		c.Next = "needs a repo change - follow the remediation nix printed above."
	}
	return c
}

// Lines renders plan-gate.sh's eval-cause block (printed after the
// "evaluation failed" line).
func (c EvalCause) Lines() []string {
	out := []string{"   eval: " + c.Class + " - " + c.Detail}
	if c.Option != "" {
		out = append(out, "   option: "+c.Option)
	}
	return append(out, "   next: "+c.Next)
}
