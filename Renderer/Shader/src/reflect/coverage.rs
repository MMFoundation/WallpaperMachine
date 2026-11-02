// This project's own code, written from the clean-room specification (no upstream code consulted).
//
//! Coverage facts: what a host needs to know to open a render pass without loading its target,
//! because one draw provably writes every texel of it. Not part of spec D's reflection; an
//! addition the engine reads when it is present and treats as "not proven" when it is absent.
//!
//! Two facts, each proven on the naga module and never guessed:
//!
//! - **The fragment stage always writes.** No `discard` anywhere in the module, no sample mask
//!   output and a four-component float colour at location 0: every fragment the rasterizer
//!   produces writes colour 0.
//! - **Where the vertex position comes from.** The clip-space position is `vec4(input.xyz, 1.0)`
//!   or that vector multiplied by a `mat4` uniform (matrix on the left), where `input` is a
//!   location-bound vertex input. The value is followed through private and local variables that
//!   are written exactly once, unconditionally and before they are read, so the copy
//!   `vec3 position = a_Position;` is seen through, and a second write (`position.x += ...`)
//!   leaves the fact unproven. Clip and cull distances also leave it unproven.
//!
//! The analysis is deliberately narrow: any statement or expression form it does not model makes
//! the answer "not proven", which costs a host nothing but the saving.

use std::collections::HashMap;

use naga::{
    AddressSpace, BinaryOperator, Binding, BuiltIn, Expression, Function, GlobalVariable, Handle, Literal,
    LocalVariable, Module, ScalarKind, Statement, TypeInner, VectorSize,
};

use super::InputNames;
use crate::reflection::PositionSource;

/// Deepest chain of variable loads, compositions and accesses followed.
const MAX_DEPTH: usize = 64;

/// Whether the fragment entry point `entry` writes colour 0 for every fragment it is run for.
pub(crate) fn fragment_always_writes(module: &Module, entry: usize) -> bool {
    let entry_point = &module.entry_points[entry];
    let any_kill = std::iter::once(&entry_point.function)
        .chain(module.functions.iter().map(|(_, f)| f))
        .any(|f| block_kills(&f.body));
    if any_kill {
        return false;
    }
    let Some(result) = &entry_point.function.result else { return false };
    let colour = |binding: &Option<Binding>, ty: Handle<naga::Type>| {
        matches!(binding, Some(Binding::Location { location: 0, blend_src: None, .. }))
            && float_vector_len(&module.types[ty].inner) == Some(4)
    };
    match &result.binding {
        Some(_) => colour(&result.binding, result.ty),
        None => {
            let TypeInner::Struct { members, .. } = &module.types[result.ty].inner else { return false };
            let masks = members.iter().any(|m| matches!(m.binding, Some(Binding::BuiltIn(BuiltIn::SampleMask))));
            !masks && members.iter().any(|m| colour(&m.binding, m.ty))
        }
    }
}

fn block_kills(block: &naga::Block) -> bool {
    block.iter().any(|statement| match statement {
        Statement::Kill => true,
        Statement::Block(b) => block_kills(b),
        Statement::If { accept, reject, .. } => block_kills(accept) || block_kills(reject),
        Statement::Switch { cases, .. } => cases.iter().any(|c| block_kills(&c.body)),
        Statement::Loop { body, continuing, .. } => block_kills(body) || block_kills(continuing),
        _ => false,
    })
}

/// The proven source of the vertex entry point's position, or `None`.
pub(crate) fn vertex_position(module: &Module, entry: usize, names: &InputNames) -> Option<PositionSource> {
    let prover = Prover::new(module, entry, names)?;
    prover.position()
}

/// The number of components of a 32-bit float scalar (1) or vector, or `None`.
fn float_vector_len(inner: &TypeInner) -> Option<u32> {
    let float = |s: &naga::Scalar| s.kind == ScalarKind::Float && s.width == 4;
    match inner {
        TypeInner::Scalar(s) if float(s) => Some(1),
        TypeInner::Vector { size, scalar } if float(scalar) => Some(match size {
            VectorSize::Bi => 2,
            VectorSize::Tri => 3,
            VectorSize::Quad => 4,
        }),
        _ => None,
    }
}

fn is_mat4(inner: &TypeInner) -> bool {
    matches!(inner, TypeInner::Matrix { columns: VectorSize::Quad, rows: VectorSize::Quad, scalar }
        if scalar.kind == ScalarKind::Float && scalar.width == 4)
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Func {
    Entry,
    Function(Handle<Function>),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Hash)]
enum Var {
    Global(Handle<GlobalVariable>),
    Local(Func, Handle<LocalVariable>),
}

/// One statement that may write a variable: where it is, and the value when it stores the whole
/// variable.
struct Write {
    func: Func,
    /// The statement's index in its function's body, `None` when it is nested in another.
    top: Option<usize>,
    whole_value: Option<Handle<Expression>>,
}

struct CallSite {
    caller: Func,
    top: Option<usize>,
}

/// One component of a vector value, as far as the proof needs to tell them apart.
#[derive(Clone, Copy, Debug, PartialEq, Eq)]
enum Component {
    /// Component `index` of the vertex input at `location`.
    Input { location: u32, index: u32 },
    /// The constant 1.0.
    One,
}

struct Prover<'a> {
    module: &'a Module,
    entry: &'a naga::EntryPoint,
    names: &'a InputNames,
    writes: HashMap<Var, Vec<Write>>,
    calls: HashMap<Handle<Function>, Vec<CallSite>>,
    /// Per function, the first top-level statement that is or contains a `return` or `discard`.
    first_exit: HashMap<Func, usize>,
    /// Where each expression is emitted: its top-level statement, `None` inside a nested block.
    emitted: HashMap<(Func, Handle<Expression>), Option<usize>>,
    /// Every `return` of the entry point: its top-level index, `None` when nested.
    entry_returns: Vec<(Option<usize>, Option<Handle<Expression>>)>,
}

impl<'a> Prover<'a> {
    /// Walks every function once; `None` when a statement the proof does not model appears.
    fn new(module: &'a Module, entry: usize, names: &'a InputNames) -> Option<Prover<'a>> {
        let mut prover = Prover {
            module,
            entry: &module.entry_points[entry],
            names,
            writes: HashMap::new(),
            calls: HashMap::new(),
            first_exit: HashMap::new(),
            emitted: HashMap::new(),
            entry_returns: Vec::new(),
        };
        let entry_point = prover.entry;
        prover.walk(Func::Entry, &entry_point.function.body, None)?;
        for (handle, function) in module.functions.iter() {
            prover.walk(Func::Function(handle), &function.body, None)?;
        }
        Some(prover)
    }

    fn function(&self, func: Func) -> &'a Function {
        match func {
            Func::Entry => &self.entry.function,
            Func::Function(handle) => &self.module.functions[handle],
        }
    }

    /// Records writes, calls, exits and emissions of `block`; `outer` is the top-level index of
    /// the statement it is nested in, `None` for a function's body.
    fn walk(&mut self, func: Func, block: &naga::Block, outer: Option<usize>) -> Option<()> {
        let f = self.function(func);
        for (i, statement) in block.iter().enumerate() {
            let index = outer.unwrap_or(i);
            let top = outer.is_none().then_some(i);
            match statement {
                Statement::Emit(range) => {
                    for handle in range.clone() {
                        self.emitted.insert((func, handle), top);
                    }
                }
                Statement::Block(b) => self.walk(func, b, Some(index))?,
                Statement::If { accept, reject, .. } => {
                    self.walk(func, accept, Some(index))?;
                    self.walk(func, reject, Some(index))?;
                }
                Statement::Switch { cases, .. } => {
                    for case in cases {
                        self.walk(func, &case.body, Some(index))?;
                    }
                }
                Statement::Loop { body, continuing, .. } => {
                    self.walk(func, body, Some(index))?;
                    self.walk(func, continuing, Some(index))?;
                }
                // They leave a loop, never the function.
                Statement::Break | Statement::Continue => {}
                Statement::Return { value } => {
                    self.exit(func, index);
                    if func == Func::Entry {
                        self.entry_returns.push((top, *value));
                    }
                }
                Statement::Kill => self.exit(func, index),
                Statement::ControlBarrier(_) | Statement::MemoryBarrier(_) | Statement::ImageStore { .. } => {}
                Statement::Store { pointer, value } => match root(f, *pointer) {
                    Root::Variable(var) => {
                        let whole = matches!(f.expressions[*pointer], Expression::GlobalVariable(_) | Expression::LocalVariable(_));
                        self.write(func, var, top, whole.then_some(*value));
                    }
                    // A write through a pointer parameter is the caller's: counted at its call.
                    Root::Argument => {}
                    Root::Other => return None,
                },
                Statement::Call { function, arguments, .. } => {
                    self.calls.entry(*function).or_default().push(CallSite { caller: func, top });
                    for argument in arguments {
                        // A pointer argument lets the callee write the variable.
                        if let Root::Variable(var) = root(f, *argument) {
                            self.write(func, var, top, None);
                        }
                    }
                }
                _ => return None,
            }
        }
        Some(())
    }

    fn exit(&mut self, func: Func, index: usize) {
        let first = self.first_exit.entry(func).or_insert(index);
        *first = (*first).min(index);
    }

    fn write(&mut self, func: Func, var: RootVar, top: Option<usize>, whole_value: Option<Handle<Expression>>) {
        let var = match var {
            RootVar::Global(g) => Var::Global(g),
            RootVar::Local(l) => Var::Local(func, l),
        };
        self.writes.entry(var).or_default().push(Write { func, top, whole_value });
    }

    /// No `return` or `discard` comes before top-level statement `index` of `func`.
    fn reached(&self, func: Func, index: usize) -> bool {
        self.first_exit.get(&func).is_none_or(|exit| *exit >= index)
    }

    /// The one call of `callee` in the module, at the top level of its caller and reached.
    fn single_call(&self, callee: Handle<Function>) -> Option<(Func, usize)> {
        let [site] = self.calls.get(&callee)?.as_slice() else { return None };
        let top = site.top?;
        self.reached(site.caller, top).then_some((site.caller, top))
    }

    /// The value a load of `var` emitted at top-level statement `at` of `func` reads: the value of
    /// the variable's only write, a whole store at the top level of its function that runs before
    /// the load.
    fn stored(&self, func: Func, at: usize, var: Var) -> Option<(Func, Handle<Expression>)> {
        let [write] = self.writes.get(&var)?.as_slice() else { return None };
        let store = write.top?;
        let value = write.whole_value?;
        if !self.reached(write.func, store) {
            return None;
        }
        let before = if write.func == func {
            store < at
        } else if let Func::Function(writer) = write.func
            && let Some((caller, call)) = self.single_call(writer)
            && caller == func
        {
            // Written by a function the reader called before the load.
            call < at
        } else if let Func::Function(reader) = func
            && let Some((caller, call)) = self.single_call(reader)
            && caller == write.func
        {
            // Read by a function the writer calls after the store.
            call > store
        } else {
            false
        };
        before.then_some((write.func, value))
    }

    fn emitted_at(&self, func: Func, handle: Handle<Expression>) -> Option<usize> {
        self.emitted.get(&(func, handle)).copied().flatten()
    }

    /// The variable a pointer expression names when it is a whole private or local variable.
    fn variable(&self, func: Func, pointer: Handle<Expression>) -> Option<Var> {
        match self.function(func).expressions[pointer] {
            Expression::GlobalVariable(g) if self.module.global_variables[g].space == AddressSpace::Private => {
                Some(Var::Global(g))
            }
            Expression::LocalVariable(l) => Some(Var::Local(func, l)),
            _ => None,
        }
    }

    /// Follows loads of variables written once to the expression that was stored.
    fn resolve(&self, func: Func, handle: Handle<Expression>, depth: usize) -> Option<(Func, Handle<Expression>)> {
        if depth > MAX_DEPTH {
            return None;
        }
        if let Expression::Load { pointer } = self.function(func).expressions[handle]
            && let Some(var) = self.variable(func, pointer)
        {
            let at = self.emitted_at(func, handle)?;
            let (writer, value) = self.stored(func, at, var)?;
            return self.resolve(writer, value, depth + 1);
        }
        Some((func, handle))
    }

    fn components(&self, func: Func, handle: Handle<Expression>, depth: usize) -> Option<Vec<Component>> {
        if depth > MAX_DEPTH {
            return None;
        }
        let (func, handle) = self.resolve(func, handle, depth + 1)?;
        let f = self.function(func);
        match &f.expressions[handle] {
            Expression::Literal(Literal::F32(v)) if *v == 1.0 => Some(vec![Component::One]),
            Expression::Constant(c) => match self.module.global_expressions[self.module.constants[*c].init] {
                Expression::Literal(Literal::F32(v)) if v == 1.0 => Some(vec![Component::One]),
                _ => None,
            },
            Expression::Compose { components, .. } => {
                let mut out = Vec::new();
                for c in components {
                    out.extend(self.components(func, *c, depth + 1)?);
                }
                Some(out)
            }
            Expression::AccessIndex { base, index } => {
                let all = self.components(func, *base, depth + 1)?;
                all.get(*index as usize).map(|c| vec![*c])
            }
            Expression::Swizzle { size, vector, pattern } => {
                let all = self.components(func, *vector, depth + 1)?;
                pattern[..*size as usize].iter().map(|p| all.get(*p as usize).copied()).collect()
            }
            Expression::FunctionArgument(k) if func == Func::Entry => {
                let argument = self.entry.function.arguments.get(*k as usize)?;
                let Some(Binding::Location { location, .. }) = argument.binding else { return None };
                let n = float_vector_len(&self.module.types[argument.ty].inner)?;
                Some((0..n).map(|index| Component::Input { location, index }).collect())
            }
            // One component of a variable written once: `position.x`.
            Expression::Load { pointer } => {
                let Expression::AccessIndex { base, index } = f.expressions[*pointer] else { return None };
                let var = self.variable(func, base)?;
                let at = self.emitted_at(func, handle)?;
                let (writer, value) = self.stored(func, at, var)?;
                let all = self.components(writer, value, depth + 1)?;
                all.get(index as usize).map(|c| vec![*c])
            }
            _ => None,
        }
    }

    /// The name of the `mat4` uniform an expression loads.
    fn matrix(&self, func: Func, handle: Handle<Expression>) -> Option<String> {
        let (func, handle) = self.resolve(func, handle, 1)?;
        let f = self.function(func);
        let Expression::Load { pointer } = f.expressions[handle] else { return None };
        let uniform = |g: Handle<GlobalVariable>| {
            let var = &self.module.global_variables[g];
            (var.space == AddressSpace::Uniform).then_some(var)
        };
        match f.expressions[pointer] {
            Expression::AccessIndex { base, index } => {
                let Expression::GlobalVariable(g) = f.expressions[base] else { return None };
                let var = uniform(g)?;
                let TypeInner::Struct { members, .. } = &self.module.types[var.ty].inner else { return None };
                let member = members.get(index as usize)?;
                if is_mat4(&self.module.types[member.ty].inner) { member.name.clone() } else { None }
            }
            Expression::GlobalVariable(g) => {
                let var = uniform(g)?;
                if is_mat4(&self.module.types[var.ty].inner) { var.name.clone() } else { None }
            }
            _ => None,
        }
    }

    fn position(&self) -> Option<PositionSource> {
        let entry = &self.entry.function;
        let result = entry.result.as_ref()?;
        // Which member of the result is the position; a clip or cull distance can drop coverage.
        let member = match &result.binding {
            Some(Binding::BuiltIn(BuiltIn::Position { .. })) => None,
            None => {
                let TypeInner::Struct { members, .. } = &self.module.types[result.ty].inner else { return None };
                let clips = members.iter().any(|m| {
                    matches!(m.binding, Some(Binding::BuiltIn(BuiltIn::ClipDistance | BuiltIn::CullDistance)))
                });
                if clips {
                    return None;
                }
                Some(members.iter().position(|m| matches!(m.binding, Some(Binding::BuiltIn(BuiltIn::Position { .. }))))?)
            }
            Some(_) => return None,
        };
        // One `return`, the entry point's last top-level statement.
        let [(Some(at), Some(value))] = self.entry_returns.as_slice() else { return None };
        if *at + 1 != entry.body.len() {
            return None;
        }
        let position = match member {
            None => *value,
            Some(m) => {
                let (func, composed) = self.resolve(Func::Entry, *value, 0)?;
                let Expression::Compose { components, .. } = &self.function(func).expressions[composed] else {
                    return None;
                };
                if func != Func::Entry {
                    return None;
                }
                *components.get(m)?
            }
        };
        let (func, position) = self.resolve(Func::Entry, position, 0)?;
        let (matrix, vector) = match self.function(func).expressions[position] {
            Expression::Binary { op: BinaryOperator::Multiply, left, right } => (Some(self.matrix(func, left)?), right),
            _ => (None, position),
        };
        let components = self.components(func, vector, 0)?;
        let [
            Component::Input { location, index: 0 },
            Component::Input { location: y, index: 1 },
            Component::Input { location: z, index: 2 },
            Component::One,
        ] = components.as_slice()
        else {
            return None;
        };
        if y != location || z != location {
            return None;
        }
        let argument = entry
            .arguments
            .iter()
            .find(|a| matches!(a.binding, Some(Binding::Location { location: l, .. }) if l == *location))?;
        let input = self.names.author(argument.name.as_deref()?).to_string();
        Some(PositionSource { input, matrix })
    }
}

enum RootVar {
    Global(Handle<GlobalVariable>),
    Local(Handle<LocalVariable>),
}

enum Root {
    Variable(RootVar),
    Argument,
    Other,
}

/// The variable a pointer expression points into, through member and element accesses.
fn root(f: &Function, mut handle: Handle<Expression>) -> Root {
    loop {
        match f.expressions[handle] {
            Expression::GlobalVariable(g) => return Root::Variable(RootVar::Global(g)),
            Expression::LocalVariable(l) => return Root::Variable(RootVar::Local(l)),
            Expression::Access { base, .. } | Expression::AccessIndex { base, .. } => handle = base,
            Expression::FunctionArgument(_) => return Root::Argument,
            _ => return Root::Other,
        }
    }
}

#[cfg(test)]
mod tests;
