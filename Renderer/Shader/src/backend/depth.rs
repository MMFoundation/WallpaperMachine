// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! A bound on how much stack the downstream compiler needs for a stage (spec A R91).
//!
//! naga reads, validates and writes expressions and statements recursively, so a text that nests
//! brackets or chains operators thousands deep overflows the small stack of an engine worker
//! thread (512 KiB). The layer may not create a thread of its own (R89) and may not crash (R91),
//! so the text is measured first and a text that is too deep is a normal failure.
//!
//! The measure adds up what is open at the deepest point of the text: each open bracket weighs
//! what its recursion costs (a block more than a parenthesis), and each operator or member access
//! in an expression that is still being read weighs one, because a chain of them is a tree as
//! deep as it is long. Measured against naga 29.0.3 in a release build on a 512 KiB stack, one
//! unit is about a kilobyte of stack in the worst of the shapes tried (nested blocks, nested
//! calls, ternaries, sums, unary chains, swizzle chains), so [`STACK_BUDGET`] leaves most of the
//! stack to the callers. Shipped and workshop shaders stay far below it.

/// The most the measure may reach.
pub const STACK_BUDGET: u32 = 128;

const BLOCK_WEIGHT: u32 = 4;
const GROUP_WEIGHT: u32 = 3;
/// An `else if` chain nests one statement per link without any bracket in between.
const ELSE_WEIGHT: u32 = 3;

struct Level {
    weight: u32,
    /// Operators seen in the expression this level is reading now.
    chain: u32,
    /// `else` links of the statement chain this level is reading now.
    elses: u32,
}

impl Level {
    fn new(weight: u32) -> Level {
        Level { weight, chain: 0, elses: 0 }
    }

    /// What this level still holds when it closes.
    fn held(&self) -> u32 {
        self.weight + self.chain + self.elses * ELSE_WEIGHT
    }
}

/// The measure of `glsl`: the largest total of open weights and expression chains at any point.
pub fn stack_cost(glsl: &str) -> u32 {
    let bytes = glsl.as_bytes();
    let mut levels = vec![Level::new(0)];
    let mut total = 0u32;
    let mut worst = 0u32;
    // Whether the previous significant byte ends an operand (so a `.` is a member access).
    let mut after_operand = false;
    // Whether the previous significant token was `else`, so that `if` continues the chain.
    let mut after_else = false;
    let mut i = 0;
    while i < bytes.len() {
        let b = bytes[i];
        match b {
            b'/' if bytes.get(i + 1) == Some(&b'/') => {
                while i < bytes.len() && bytes[i] != b'\n' {
                    i += 1;
                }
                continue;
            }
            b'/' if bytes.get(i + 1) == Some(&b'*') => {
                i += 2;
                while i < bytes.len() && !(bytes[i] == b'*' && bytes.get(i + 1) == Some(&b'/')) {
                    i += 1;
                }
                i += 2;
                continue;
            }
            b if b.is_ascii_whitespace() => {
                i += 1;
                continue;
            }
            b'0'..=b'9' => {
                i = number_end(bytes, i);
                after_operand = true;
                continue;
            }
            b'.' if !after_operand && bytes.get(i + 1).is_some_and(u8::is_ascii_digit) => {
                i = number_end(bytes, i);
                after_operand = true;
                continue;
            }
            b if b.is_ascii_alphabetic() || b == b'_' => {
                let start = i;
                while i < bytes.len() && (bytes[i].is_ascii_alphanumeric() || bytes[i] == b'_') {
                    i += 1;
                }
                let word = &bytes[start..i];
                let level = levels.last_mut().expect("the outer level stays");
                if word == b"else" {
                    level.elses += 1;
                    total = total.saturating_add(ELSE_WEIGHT);
                    worst = worst.max(total);
                } else if !(word == b"if" && after_else) {
                    // Any other statement ends the chain.
                    total = total.saturating_sub(level.elses * ELSE_WEIGHT);
                    level.elses = 0;
                }
                after_else = word == b"else";
                after_operand = true;
                continue;
            }
            b'{' | b'(' | b'[' => {
                after_else = false;
                let weight = if b == b'{' { BLOCK_WEIGHT } else { GROUP_WEIGHT };
                levels.push(Level::new(weight));
                total = total.saturating_add(weight);
                after_operand = false;
            }
            b'}' | b')' | b']' => {
                after_else = false;
                if levels.len() > 1 {
                    let level = levels.pop().expect("more than the outer level");
                    total = total.saturating_sub(level.held());
                }
                after_operand = true;
            }
            b',' | b';' => {
                after_else = false;
                let level = levels.last_mut().expect("the outer level stays");
                total = total.saturating_sub(level.chain);
                level.chain = 0;
                after_operand = false;
            }
            b'+' | b'-' | b'*' | b'/' | b'%' | b'<' | b'>' | b'=' | b'!' | b'~' | b'&' | b'|' | b'^' | b'?' | b':'
            | b'.' => {
                let level = levels.last_mut().expect("the outer level stays");
                after_else = false;
                level.chain += 1;
                total = total.saturating_add(1);
                // `++` and `--` end an operand when postfix; either way the next byte decides nothing.
                after_operand = false;
            }
            _ => {
                after_else = false;
                after_operand = false;
            }
        }
        worst = worst.max(total);
        i += 1;
    }
    worst
}

/// The end of the numeric literal that starts at `start`: digits, letters (suffixes, hex), dots,
/// and a sign right after an exponent.
fn number_end(bytes: &[u8], start: usize) -> usize {
    let mut i = start;
    while i < bytes.len() {
        let b = bytes[i];
        let exponent_sign = (b == b'+' || b == b'-')
            && i > start
            && matches!(bytes[i - 1], b'e' | b'E')
            && !bytes[start..i].starts_with(b"0x")
            && !bytes[start..i].starts_with(b"0X");
        if b.is_ascii_alphanumeric() || b == b'.' || b == b'_' || exponent_sign {
            i += 1;
        } else {
            break;
        }
    }
    i
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn plain_shaders_measure_small() {
        let text = "#version 450\nvoid main() {\n  float a = (1.0 + 2.0) * g(3.0, 4.0); // (((((\n  /* {{{{ */ gl_Position = vec4(a);\n}\n";
        assert!(stack_cost(text) < 20, "{}", stack_cost(text));
    }

    #[test]
    fn nesting_adds_up_by_weight() {
        assert_eq!(stack_cost("{((["), BLOCK_WEIGHT + 2 * GROUP_WEIGHT + GROUP_WEIGHT);
        assert_eq!(stack_cost("{{{{}}}}"), 4 * BLOCK_WEIGHT);
        // closed levels no longer count
        assert_eq!(stack_cost("(((())))((()))"), 4 * GROUP_WEIGHT);
    }

    #[test]
    fn chains_count_while_the_expression_is_open_and_reset_at_its_end() {
        assert_eq!(stack_cost("a+b+c+d;"), 3);
        assert_eq!(stack_cost("a+b; c+d+e;"), 2);
        assert_eq!(stack_cost("f(a+b, c+d)"), GROUP_WEIGHT + 1);
        // an operator before an open bracket stays part of the depth
        assert_eq!(stack_cost("a+(b+(c+d))"), 1 + GROUP_WEIGHT + 1 + GROUP_WEIGHT + 1);
        assert_eq!(stack_cost("v.x.y.z"), 3);
    }

    #[test]
    fn an_else_if_chain_counts_by_link_and_separate_statements_do_not_add_up() {
        let chain = |links: usize| format!("if (a) {{ x; }}{}", " else if (b) { y; }".repeat(links));
        assert_eq!(stack_cost(&chain(10)) - stack_cost(&chain(9)), ELSE_WEIGHT);
        assert!(stack_cost(&chain(300)) > STACK_BUDGET);
        let sequence = "if (a) { x; } else { y; } ".repeat(500);
        assert!(stack_cost(&sequence) < 2 * BLOCK_WEIGHT + ELSE_WEIGHT + 2 * GROUP_WEIGHT, "{}", stack_cost(&sequence));
    }

    #[test]
    fn numbers_and_comments_are_not_operators() {
        assert_eq!(stack_cost("a = 1.5e-3 + .5f + 0x1F + 2.0;"), 4);
        assert_eq!(stack_cost("a = 1.0; // + + + +\n b; /* - - - */"), 1);
    }

    #[test]
    fn unbalanced_text_does_not_underflow() {
        assert_eq!(stack_cost(")))]]]}}}"), 0);
        assert!(stack_cost("((((") > 0);
    }

    #[test]
    fn hostile_shapes_exceed_the_budget_and_ordinary_depth_does_not() {
        let deep = |open: &str, close: &str, n: usize| format!("{}x{}", open.repeat(n), close.repeat(n));
        assert!(stack_cost(&deep("(", ")", 1000)) > STACK_BUDGET);
        assert!(stack_cost(&deep("{", "}", 200)) > STACK_BUDGET);
        assert!(stack_cost(&deep("f(", ")", 200)) > STACK_BUDGET);
        assert!(stack_cost(&vec!["1.0"; 400].join("+")) > STACK_BUDGET);
        assert!(stack_cost(&"- ".repeat(400)) > STACK_BUDGET);
        assert!(stack_cost(&deep("(", ")", 20)) < STACK_BUDGET);
        assert!(stack_cost(&vec!["1.0"; 60].join("+")) < STACK_BUDGET);
    }
}
