// Copyright (c) 2019-2020 Alexander Medvednikov. All rights reserved.
// Use of this source code is governed by an MIT license
// that can be found in the LICENSE file.
module gen

import strings
import v.ast
import v.table
import v.pref
import v.token
import v.util
import v.depgraph

// NB: keywords after 'new' are reserved in C++
const (
	c_reserved = ['delete', 'exit', 'link', 'unix', 'error', 'calloc', 'malloc', 'free', 'panic',
		'auto', 'char', 'default', 'do', 'double', 'extern', 'float', 'inline', 'int', 'long', 'register',
		'restrict', 'short', 'signed', 'sizeof', 'static', 'switch', 'typedef', 'union', 'unsigned', 'void',
		'volatile', 'while', 'new', 'namespace', 'class', 'typename']
	// same order as in token.Kind
	cmp_str    = ['eq', 'ne', 'gt', 'lt', 'ge', 'le']
	// when operands are switched
	cmp_rev    = ['eq', 'ne', 'le', 'ge', 'lt', 'gt']
)

struct Gen {
	table                &table.Table
	pref                 &pref.Preferences
	module_built         string
mut:
	out                  strings.Builder
	cheaders             strings.Builder
	includes             strings.Builder // all C #includes required by V modules
	typedefs             strings.Builder
	typedefs2            strings.Builder
	type_definitions     strings.Builder // typedefs, defines etc (everything that goes to the top of the file)
	definitions          strings.Builder // typedefs, defines etc (everything that goes to the top of the file)
	inits                map[string]strings.Builder // contents of `void _vinit(){}`
	cleanups             map[string]strings.Builder // contents of `void _vcleanup(){}`
	gowrappers           strings.Builder // all go callsite wrappers
	stringliterals       strings.Builder // all string literals (they depend on tos3() beeing defined
	auto_str_funcs       strings.Builder // function bodies of all auto generated _str funcs
	comptime_defines     strings.Builder // custom defines, given by -d/-define flags on the CLI
	pcs_declarations     strings.Builder // -prof profile counter declarations for each function
	hotcode_definitions  strings.Builder // -live declarations & functions
	options              strings.Builder // `Option_xxxx` types
	json_forward_decls   strings.Builder // json type forward decls
	enum_typedefs        strings.Builder // enum types
	sql_buf              strings.Builder // for writing exprs to args via `sqlite3_bind_int()` etc
	file                 ast.File
	fn_decl              &ast.FnDecl // pointer to the FnDecl we are currently inside otherwise 0
	last_fn_c_name       string
	tmp_count            int
	variadic_args        map[string]int
	is_c_call            bool // e.g. `C.printf("v")`
	is_assign_lhs        bool // inside left part of assign expr (for array_set(), etc)
	is_assign_rhs        bool // inside right part of assign after `=` (val expr)
	is_array_set         bool
	is_amp               bool // for `&Foo{}` to merge PrefixExpr `&` and StructInit `Foo{}`; also for `&byte(0)` etc
	is_sql               bool // Inside `sql db{}` statement, generating sql instead of C (e.g. `and` instead of `&&` etc)
	is_shared            bool // for initialization of hidden mutex in `[rw]shared` literals
	optionals            []string // to avoid duplicates TODO perf, use map
	shareds              []int // types with hidden mutex for which decl has been emitted
	inside_ternary       int // ?: comma separated statements on a single line
	inside_map_postfix   bool // inside map++/-- postfix expr
	inside_map_infix     bool // inside map<</+=/-= infix expr
	ternary_names        map[string]string
	ternary_level_names  map[string][]string
	stmt_path_pos        []int
	right_is_opt         bool
	autofree             bool
	indent               int
	empty_line           bool
	is_test              bool
	assign_op            token.Kind // *=, =, etc (for array_set)
	defer_stmts          []ast.DeferStmt
	defer_ifdef          string
	defer_profile_code   string
	str_types            []string // types that need automatic str() generation
	threaded_fns         []string // for generating unique wrapper types and fns for `go xxx()`
	array_fn_definitions []string // array equality functions that have been defined
	map_fn_definitions   []string // map equality functions that have been defined
	is_json_fn           bool // inside json.encode()
	json_types           []string // to avoid json gen duplicates
	pcs                  []ProfileCounterMeta // -prof profile counter fn_names => fn counter name
	attrs                []string // attributes before next decl stmt
	is_builtin_mod       bool
	hotcode_fn_names     []string
	// cur_fn               ast.FnDecl
	cur_generic_type     table.Type // `int`, `string`, etc in `foo<T>()`
	sql_i                int
	sql_stmt_name        string
	sql_side             SqlExprSide // left or right, to distinguish idents in `name == name`
	inside_vweb_tmpl     bool
	inside_return        bool
	strs_to_free         string
	inside_call          bool
	has_main             bool
	inside_const         bool
	comp_for_method      string // $for method in T {
}

const (
	tabs = ['', '\t', '\t\t', '\t\t\t', '\t\t\t\t', '\t\t\t\t\t', '\t\t\t\t\t\t', '\t\t\t\t\t\t\t',
		'\t\t\t\t\t\t\t\t',
	]
)

pub fn cgen(files []ast.File, table &table.Table, pref &pref.Preferences) string {
	// println('start cgen2')
	mut g := Gen{
		out: strings.new_builder(1000)
		cheaders: strings.new_builder(8192)
		includes: strings.new_builder(100)
		typedefs: strings.new_builder(100)
		typedefs2: strings.new_builder(100)
		type_definitions: strings.new_builder(100)
		definitions: strings.new_builder(100)
		gowrappers: strings.new_builder(100)
		stringliterals: strings.new_builder(100)
		auto_str_funcs: strings.new_builder(100)
		comptime_defines: strings.new_builder(100)
		pcs_declarations: strings.new_builder(100)
		hotcode_definitions: strings.new_builder(100)
		options: strings.new_builder(100)
		json_forward_decls: strings.new_builder(100)
		enum_typedefs: strings.new_builder(100)
		sql_buf: strings.new_builder(100)
		table: table
		pref: pref
		fn_decl: 0
		autofree: true
		indent: -1
		module_built: pref.path.after('vlib/')
	}
	for mod in g.table.modules {
		g.inits[mod] = strings.new_builder(100)
		g.cleanups[mod] = strings.new_builder(100)
	}
	g.init()
	//
	mut tests_inited := false
	mut autofree_used := false
	for file in files {
		g.file = file
		// println('\ncgen "$g.file.path" nr_stmts=$file.stmts.len')
		// building_v := true && (g.file.path.contains('/vlib/') || g.file.path.contains('cmd/v'))
		is_test := g.file.path.ends_with('.vv') || g.file.path.ends_with('_test.v')
		if g.file.path.ends_with('_test.v') {
			g.is_test = is_test
		}
		if g.file.path == '' || !g.pref.autofree {
			// cgen test or building V
			// println('autofree=false')
			g.autofree = false
		} else {
			g.autofree = true
			autofree_used = true
		}
		// anon fn may include assert and thus this needs
		// to be included before any test contents are written
		if g.is_test && !tests_inited {
			g.write_tests_main()
			tests_inited = true
		}
		g.stmts(file.stmts)
	}
	if autofree_used {
		g.autofree = true // so that void _vcleanup is generated
	}
	g.write_variadic_types()
	// g.write_str_definitions()
	if g.pref.build_mode != .build_module {
		// no init in builtin.o
		g.write_init_function()
	}
	//
	g.finish()
	//
	mut b := strings.new_builder(250000)
	b.write(g.hashes())
	b.write(g.comptime_defines.str())
	b.writeln('\n// V typedefs:')
	b.write(g.typedefs.str())
	b.writeln('\n// V typedefs2:')
	b.write(g.typedefs2.str())
	b.writeln('\n// V cheaders:')
	b.write(g.cheaders.str())
	b.writeln('\n// V includes:')
	b.write(g.includes.str())
	b.writeln('\n// Enum definitions:')
	b.write(g.enum_typedefs.str())
	b.writeln('\n// V type definitions:')
	b.write(g.type_definitions.str())
	b.writeln('\n// V Option_xxx definitions:')
	b.write(g.options.str())
	b.writeln('\n// V json forward decls:')
	b.write(g.json_forward_decls.str())
	b.writeln('\n// V definitions:')
	b.write(g.definitions.str())
	if g.pcs_declarations.len > 0 {
		b.writeln('\n// V profile counters:')
		b.write(g.pcs_declarations.str())
	}
	interface_table := g.interface_table()
	if interface_table.len > 0 {
		b.writeln('\n// V interface table:')
		b.write(interface_table)
	}
	if g.gowrappers.len > 0 {
		b.writeln('\n// V gowrappers:')
		b.write(g.gowrappers.str())
	}
	if g.hotcode_definitions.len > 0 {
		b.writeln('\n// V hotcode definitions:')
		b.write(g.hotcode_definitions.str())
	}
	if g.stringliterals.len > 0 {
		b.writeln('\n// V stringliterals:')
		b.write(g.stringliterals.str())
	}
	if g.auto_str_funcs.len > 0 {
		if g.pref.build_mode != .build_module {
			b.writeln('\n// V auto str functions:')
			b.write(g.auto_str_funcs.str())
		}
	}
	b.writeln('\n// V out')
	b.write(g.out.str())
	b.writeln('\n// THE END.')
	return b.str()
}

pub fn (g Gen) hashes() string {
	mut res := c_commit_hash_default.replace('@@@', util.vhash())
	res += c_current_commit_hash_default.replace('@@@', util.githash(g.pref.building_v))
	return res
}

pub fn (mut g Gen) init() {
	if g.pref.custom_prelude != '' {
		g.cheaders.writeln(g.pref.custom_prelude)
	} else if !g.pref.no_preludes {
		g.cheaders.writeln('// Generated by the V compiler')
		g.cheaders.writeln('#include <inttypes.h>') // int64_t etc
		g.cheaders.writeln(c_builtin_types)
		if g.pref.is_bare {
			g.cheaders.writeln(bare_c_headers)
		} else {
			g.cheaders.writeln(c_headers)
		}
		g.definitions.writeln('void _STR_PRINT_ARG(const char*, char**, int*, int*, int, ...);')
		g.definitions.writeln('string _STR(const char*, int, ...);')
		g.definitions.writeln('string _STR_TMP(const char*, ...);')
	}
	g.write_builtin_types()
	g.write_typedef_types()
	g.write_typeof_functions()
	if g.pref.build_mode != .build_module {
		// _STR functions should not be defined in builtin.o
		g.write_str_fn_definitions()
	}
	g.write_sorted_types()
	g.write_multi_return_types()
	g.definitions.writeln('// end of definitions #endif')
	//
	g.stringliterals.writeln('')
	g.stringliterals.writeln('// >> string literal consts')
	if g.pref.build_mode != .build_module {
		g.stringliterals.writeln('void vinit_string_literals(){')
	}
	if g.pref.compile_defines_all.len > 0 {
		g.comptime_defines.writeln('// V compile time defines by -d or -define flags:')
		g.comptime_defines.writeln('//     All custom defines      : ' + g.pref.compile_defines_all.join(','))
		g.comptime_defines.writeln('//     Turned ON custom defines: ' + g.pref.compile_defines.join(','))
		for cdefine in g.pref.compile_defines {
			g.comptime_defines.writeln('#define CUSTOM_DEFINE_$cdefine')
		}
		g.comptime_defines.writeln('')
	}
	if g.pref.is_debug || 'debug' in g.pref.compile_defines {
		g.comptime_defines.writeln('#define _VDEBUG (1)')
	}
	if g.pref.is_test || 'test' in g.pref.compile_defines {
		g.comptime_defines.writeln('#define _VTEST (1)')
	}
	if g.pref.autofree {
		g.comptime_defines.writeln('#define _VAUTOFREE (1)')
		// g.comptime_defines.writeln('unsigned char* g_cur_str;')
	}
	if g.pref.prealloc {
		g.comptime_defines.writeln('#define _VPREALLOC (1)')
	}
	if g.pref.is_livemain || g.pref.is_liveshared {
		g.generate_hotcode_reloading_declarations()
	}
}

pub fn (mut g Gen) finish() {
	if g.pref.build_mode != .build_module {
		g.stringliterals.writeln('}')
	}
	g.stringliterals.writeln('// << string literal consts')
	g.stringliterals.writeln('')
	if g.pref.is_prof {
		g.gen_vprint_profile_stats()
	}
	if g.pref.is_livemain || g.pref.is_liveshared {
		g.generate_hotcode_reloader_code()
	}
	if !g.pref.is_test {
		g.gen_c_main()
	}
}

pub fn (mut g Gen) write_typeof_functions() {
	g.writeln('')
	g.writeln('// >> typeof() support for sum types')
	for typ in g.table.types {
		if typ.kind == .sum_type {
			sum_info := typ.info as table.SumType
			tidx := g.table.find_type_idx(typ.name)
			g.writeln('char * v_typeof_sumtype_${tidx}(int sidx) { /* $typ.name */ ')
			g.writeln('	switch(sidx) {')
			g.writeln('		case $tidx: return "${util.strip_main_name(typ.name)}";')
			for v in sum_info.variants {
				subtype := g.table.get_type_symbol(v)
				g.writeln('		case $v: return "${util.strip_main_name(subtype.name)}";')
			}
			g.writeln('		default: return "unknown ${util.strip_main_name(typ.name)}";')
			g.writeln('	}')
			g.writeln('}')
		}
	}
	g.writeln('// << typeof() support for sum types')
	g.writeln('')
}

// V type to C type
fn (g &Gen) typ(t table.Type) string {
	styp := g.base_type(t)
	if t.has_flag(.optional) {
		// Register an optional if it's not registered yet
		return g.register_optional(t)
	}
	/*
	if styp.starts_with('C__') {
		return styp[3..]
	}
	*/
	return styp
}

fn (g &Gen) base_type(t table.Type) string {
	share := t.share()
	mut styp := if share == .atomic_t { t.atomic_typename() } else { g.cc_type(t) }
	if t.has_flag(.shared_f) {
		styp = g.find_or_register_shared(t, styp)
	}
	nr_muls := t.nr_muls()
	if nr_muls > 0 {
		styp += strings.repeat(`*`, nr_muls)
	}
	return styp
}

// TODO this really shouldnt be seperate from typ
// but I(emily) would rather have this generation
// all unified in one place so that it doesnt break
// if one location changes
fn (g &Gen) optional_type_name(t table.Type) (string, string) {
	base := g.base_type(t)
	mut styp := 'Option_$base'
	if t.is_ptr() {
		styp = styp.replace('*', '_ptr')
	}
	return styp, base
}

fn (g &Gen) optional_type_text(styp, base string) string {
	x := styp // .replace('*', '_ptr')			// handle option ptrs
	// replace void with something else
	size := if base == 'void' { 'int' } else { base }
	ret := 'struct $x {
	bool ok;
	bool is_none;
	string v_error;
	int ecode;
	byte data[sizeof($size)];
}'
	return ret
}

fn (mut g Gen) register_optional(t table.Type) string {
	// g.typedefs2.writeln('typedef Option $x;')
	styp, base := g.optional_type_name(t)
	if styp !in g.optionals {
		no_ptr := base.replace('*', '_ptr')
		typ := if base == 'void' { 'void*' } else { base }
		g.hotcode_definitions.writeln('typedef struct {
			$typ  data;
			string error;
			int    ecode;
			bool   ok;
			bool   is_none;
		} Option2_$no_ptr;')
		// println(styp)
		g.typedefs2.writeln('typedef struct $styp $styp;')
		g.options.write(g.optional_type_text(styp, base))
		g.options.writeln(';\n')
		g.optionals << styp.clone()
	}
	return styp
}

fn (mut g Gen) find_or_register_shared(t table.Type, base string) string {
	sh_typ := '__shared__$base'
	t_idx := t.idx()
	if t_idx in g.shareds {
		return sh_typ
	}
	mtx_typ := 'sync__RwMutex'
	g.hotcode_definitions.writeln('struct $sh_typ { $base val; $mtx_typ* mtx; };')
	g.typedefs2.writeln('typedef struct $sh_typ $sh_typ;')
	// println('registered shared type $sh_typ')
	g.shareds << t_idx
	return sh_typ
}

// cc_type returns the Cleaned Concrete Type name, *without ptr*,
// i.e. it's always just Cat, not Cat_ptr:
fn (g &Gen) cc_type(t table.Type) string {
	sym := g.table.get_type_symbol(g.unwrap_generic(t))
	mut styp := util.no_dots(sym.name)
	if sym.kind == .struct_ {
		info := sym.info as table.Struct
		if info.generic_types.len > 0 {
			mut sgtyps := '_T'
			for gt in info.generic_types {
				gts := g.table.get_type_symbol(if gt.has_flag(.generic) { g.unwrap_generic(gt) } else { gt })
				sgtyps += '_$gts.name'
			}
			styp += sgtyps
		} else if styp.contains('<') {
			// TODO: yuck
			styp = styp.replace('<', '_T_').replace('>', '').replace(',', '_')
		}
	}
	if styp.starts_with('C__') {
		styp = styp[3..]
		if sym.kind == .struct_ {
			info := sym.info as table.Struct
			if !info.is_typedef {
				styp = 'struct $styp'
			}
		}
	}
	return styp
}

//
pub fn (mut g Gen) write_typedef_types() {
	g.typedefs.writeln('
typedef struct {
	void* _object;
	int _interface_idx;
} _Interface;
')
	for typ in g.table.types {
		match typ.kind {
			.alias {
				parent := &g.table.types[typ.parent_idx]
				styp := util.no_dots(typ.name)
				is_c_parent := parent.name.len > 2 && parent.name[0] == `C` && parent.name[1] == `.`
				parent_styp := if is_c_parent { 'struct ' + util.no_dots(parent.name[2..]) } else { util.no_dots(parent.name) }
				g.type_definitions.writeln('typedef $parent_styp $styp;')
			}
			.array {
				styp := util.no_dots(typ.name)
				g.type_definitions.writeln('typedef array $styp;')
			}
			.interface_ {
				g.type_definitions.writeln('typedef _Interface ${c_name(typ.name)};')
			}
			.map {
				styp := util.no_dots(typ.name)
				g.type_definitions.writeln('typedef map $styp;')
			}
			.function {
				info := typ.info as table.FnType
				func := info.func
				sym := g.table.get_type_symbol(func.return_type)
				is_multi := sym.kind == .multi_return
				is_fn_sig := func.name == ''
				not_anon := !info.is_anon
				if !info.has_decl && !is_multi && (not_anon || is_fn_sig) {
					fn_name := if func.language == .c {
						util.no_dots(func.name)
					} else if info.is_anon {
						typ.name
					} else {
						c_name(func.name)
					}
					g.type_definitions.write('typedef ${g.typ(func.return_type)} (*$fn_name)(')
					for i, arg in func.args {
						g.type_definitions.write(g.typ(arg.typ))
						if i < func.args.len - 1 {
							g.type_definitions.write(',')
						}
					}
					g.type_definitions.writeln(');')
				}
			}
			else {
				continue
			}
		}
	}
}

pub fn (mut g Gen) write_multi_return_types() {
	g.type_definitions.writeln('// multi return structs')
	for typ in g.table.types {
		// sym := g.table.get_type_symbol(typ)
		if typ.kind != .multi_return {
			continue
		}
		name := util.no_dots(typ.name)
		info := typ.info as table.MultiReturn
		g.type_definitions.writeln('typedef struct {')
		// TODO copy pasta StructDecl
		// for field in struct_info.fields {
		for i, mr_typ in info.types {
			type_name := g.typ(mr_typ)
			g.type_definitions.writeln('\t$type_name arg$i;')
		}
		g.type_definitions.writeln('} $name;\n')
		// g.typedefs.writeln('typedef struct $name $name;')
	}
}

pub fn (mut g Gen) write_variadic_types() {
	if g.variadic_args.len > 0 {
		g.type_definitions.writeln('// variadic structs')
	}
	for type_str, arg_len in g.variadic_args {
		typ := table.Type(type_str.int())
		type_name := g.typ(typ)
		struct_name := 'varg_' + type_name.replace('*', '_ptr')
		g.type_definitions.writeln('struct $struct_name {')
		g.type_definitions.writeln('\tint len;')
		g.type_definitions.writeln('\t$type_name args[$arg_len];')
		g.type_definitions.writeln('};\n')
		g.typedefs.writeln('typedef struct $struct_name $struct_name;')
	}
}

pub fn (g Gen) save() {
}

pub fn (mut g Gen) write(s string) {
	if g.indent > 0 && g.empty_line {
		if g.indent < tabs.len {
			g.out.write(tabs[g.indent])
		} else {
			for _ in 0 .. g.indent {
				g.out.write('\t')
			}
		}
	}
	g.out.write(s)
	g.empty_line = false
}

pub fn (mut g Gen) writeln(s string) {
	if g.indent > 0 && g.empty_line {
		if g.indent < tabs.len {
			g.out.write(tabs[g.indent])
		} else {
			for _ in 0 .. g.indent {
				g.out.write('\t')
			}
		}
	}
	g.out.writeln(s)
	g.empty_line = true
}

pub fn (mut g Gen) new_tmp_var() string {
	g.tmp_count++
	return '_t$g.tmp_count'
}

pub fn (mut g Gen) reset_tmp_count() {
	g.tmp_count = 0
}

fn (mut g Gen) decrement_inside_ternary() {
	key := g.inside_ternary.str()
	for name in g.ternary_level_names[key] {
		g.ternary_names.delete(name)
	}
	g.ternary_level_names.delete(key)
	g.inside_ternary--
}

fn (mut g Gen) stmts(stmts []ast.Stmt) {
	g.indent++
	if g.inside_ternary > 0 {
		g.write('(')
	}
	for i, stmt in stmts {
		g.stmt(stmt)
		if g.inside_ternary > 0 && i < stmts.len - 1 {
			g.write(',')
		}
		// clear attrs on next non Attr stmt
		if stmt !is ast.Attr {
			g.attrs = []
		}
	}
	g.indent--
	if g.inside_ternary > 0 {
		g.write('')
		g.write(')')
	}
	if g.pref.autofree && g.pref.experimental && !g.inside_vweb_tmpl && stmts.len > 0 {
		// use the first stmt to get the scope
		stmt := stmts[0]
		// stmt := stmts[stmts.len-1]
		if stmt !is ast.FnDecl {
			// g.writeln('// autofree scope')
			// g.writeln('// autofree_scope_vars($stmt.position().pos) | ${typeof(stmt)}')
			// go back 1 position is important so we dont get the
			// internal scope of for loops and possibly other nodes
			g.autofree_scope_vars(stmt.position().pos - 1)
		}
	}
}

fn (mut g Gen) stmt(node ast.Stmt) {
	g.stmt_path_pos << g.out.len
	defer {
		// If have temporary string exprs to free after this statement, do it. e.g.:
		// `foo('a' + 'b')` => `tmp := 'a' + 'b'; foo(tmp); string_free(&tmp);`
		if g.pref.autofree {
			if g.strs_to_free != '' {
				g.writeln(g.strs_to_free)
				g.strs_to_free = ''
			}
		}
	}
	// println('cgen.stmt()')
	// g.writeln('//// stmt start')
	match node {
		ast.AssertStmt {
			g.gen_assert_stmt(node)
		}
		ast.AssignStmt {
			g.gen_assign_stmt(node)
		}
		ast.Attr {
			g.attrs << node.name
			g.writeln('// Attr: [$node.name]')
		}
		ast.Block {
			g.writeln('{')
			g.stmts(node.stmts)
			g.writeln('}')
		}
		ast.BranchStmt {
			// continue or break
			g.write(node.tok.kind.str())
			g.writeln(';')
		}
		ast.ConstDecl {
			// if g.pref.build_mode != .build_module {
			g.const_decl(node)
			// }
		}
		ast.CompFor {
			g.comp_for(node)
		}
		ast.CompIf {
			g.comp_if(node)
		}
		ast.DeferStmt {
			mut defer_stmt := *node
			defer_stmt.ifdef = g.defer_ifdef
			g.defer_stmts << defer_stmt
		}
		ast.EnumDecl {
			enum_name := util.no_dots(node.name)
			g.enum_typedefs.writeln('typedef enum {')
			mut cur_enum_expr := ''
			mut cur_enum_offset := 0
			for field in node.fields {
				g.enum_typedefs.write('\t${enum_name}_$field.name')
				if field.has_expr {
					g.enum_typedefs.write(' = ')
					pos := g.out.len
					g.expr(field.expr)
					expr_str := g.out.after(pos)
					g.out.go_back(expr_str.len)
					g.enum_typedefs.write(expr_str)
					cur_enum_expr = expr_str
					cur_enum_offset = 0
				}
				cur_value := if cur_enum_offset > 0 { '$cur_enum_expr+$cur_enum_offset' } else { cur_enum_expr }
				g.enum_typedefs.writeln(', // $cur_value')
				cur_enum_offset++
			}
			g.enum_typedefs.writeln('} $enum_name;\n')
		}
		ast.ExprStmt {
			g.expr(node.expr)
			if g.inside_ternary == 0 && !node.is_expr && !(node.expr is ast.IfExpr) {
				g.writeln(';')
			}
		}
		ast.FnDecl {
			// g.tmp_count = 0 TODO
			mut skip := false
			pos := g.out.buf.len
			if g.pref.build_mode == .build_module {
				if !node.name.starts_with(g.module_built + '.') && node.mod != g.module_built {
					// Skip functions that don't have to be generated
					// for this module.
					skip = true
				}
				if g.is_builtin_mod && g.module_built == 'builtin' {
					skip = false
				}
				if !skip {
					println('build module `$g.module_built` fn `$node.name`')
				}
			}
			if g.pref.use_cache {
				if node.mod != 'main' {
					skip = true
				}
			}
			keep_fn_decl := g.fn_decl
			g.fn_decl = node
			if node.name == 'main.main' {
				g.has_main = true
			}
			if node.name == 'backtrace' ||
				node.name == 'backtrace_symbols' ||
				node.name == 'backtrace_symbols_fd' {
				g.write('\n#ifndef __cplusplus\n')
			}
			g.gen_fn_decl(node, skip)
			if node.name == 'backtrace' ||
				node.name == 'backtrace_symbols' ||
				node.name == 'backtrace_symbols_fd' {
				g.write('\n#endif\n')
			}
			g.fn_decl = keep_fn_decl
			if skip {
				g.out.go_back_to(pos)
			}
			if node.language != .c {
				g.writeln('')
			}
		}
		ast.ForCStmt {
			g.write('for (')
			if !node.has_init {
				g.write('; ')
			} else {
				g.stmt(node.init)
				// Remove excess return and add space
				if g.out.last_n(1) == '\n' {
					g.out.go_back(1)
					g.empty_line = false
					g.write(' ')
				}
			}
			if node.has_cond {
				g.expr(node.cond)
			}
			g.write('; ')
			if node.has_inc {
				g.stmt(node.inc)
			}
			g.writeln(') {')
			g.stmts(node.stmts)
			g.writeln('}')
		}
		ast.ForInStmt {
			g.for_in(node)
		}
		ast.ForStmt {
			g.write('while (')
			if node.is_inf {
				g.write('1')
			} else {
				g.expr(node.cond)
			}
			g.writeln(') {')
			g.stmts(node.stmts)
			g.writeln('}')
		}
		ast.GlobalDecl {
			styp := g.typ(node.typ)
			g.definitions.writeln('static $styp $node.name; // global')
		}
		ast.GoStmt {
			g.go_stmt(node)
		}
		ast.GotoLabel {
			g.writeln('$node.name: {}')
		}
		ast.GotoStmt {
			g.writeln('goto $node.name;')
		}
		ast.HashStmt {
			// #include etc
			typ := node.val.all_before(' ')
			if typ == 'include' {
				g.includes.writeln('// added by module `$node.mod`:')
				g.includes.writeln('#$node.val')
			}
			if typ == 'define' {
				g.includes.writeln('#$node.val')
			}
		}
		ast.Import {}
		ast.InterfaceDecl {
			// definitions are sorted and added in write_types
		}
		ast.Module {
			g.is_builtin_mod = node.name == 'builtin'
		}
		ast.Return {
			g.write_defer_stmts_when_needed()
			if g.pref.autofree {
				g.write_autofree_stmts_when_needed(node)
			}
			g.return_statement(node)
		}
		ast.SqlStmt {
			g.sql_stmt(node)
		}
		ast.StructDecl {
			name := if node.language == .c { util.no_dots(node.name) } else { c_name(node.name) }
			// g.writeln('typedef struct {')
			// for field in it.fields {
			// field_type_sym := g.table.get_type_symbol(field.typ)
			// g.writeln('\t$field_type_sym.name $field.name;')
			// }
			// g.writeln('} $name;')
			if node.language == .c {
				return
			}
			if node.is_union {
				g.typedefs.writeln('typedef union $name $name;')
			} else {
				g.typedefs.writeln('typedef struct $name $name;')
			}
		}
		ast.TypeDecl {
			g.writeln('// TypeDecl')
		}
		ast.UnsafeStmt {
			g.writeln('{ // Unsafe block')
			g.stmts(node.stmts)
			g.writeln('}')
		}
	}
	g.stmt_path_pos.delete(g.stmt_path_pos.len - 1)
}

fn (mut g Gen) write_defer_stmts() {
	for defer_stmt in g.defer_stmts {
		g.writeln('// Defer begin')
		if defer_stmt.ifdef.len > 0 {
			g.writeln(defer_stmt.ifdef)
			g.stmts(defer_stmt.stmts)
			g.writeln('')
			g.writeln('#endif')
		} else {
			g.indent--
			g.stmts(defer_stmt.stmts)
			g.indent++
		}
		g.writeln('// Defer end')
	}
}

fn (mut g Gen) for_in(it ast.ForInStmt) {
	if it.is_range {
		// `for x in 1..10 {`
		i := if it.val_var == '_' { g.new_tmp_var() } else { c_name(it.val_var) }
		g.write('for (int $i = ')
		g.expr(it.cond)
		g.write('; $i < ')
		g.expr(it.high)
		g.writeln('; ++$i) {')
		g.stmts(it.stmts)
		g.writeln('}')
	} else if it.kind == .array {
		// `for num in nums {`
		g.writeln('// FOR IN array')
		styp := g.typ(it.val_type)
		cond_type_is_ptr := it.cond_type.is_ptr()
		atmp := g.new_tmp_var()
		atmp_type := if cond_type_is_ptr { 'array *' } else { 'array' }
		g.write('$atmp_type $atmp = ')
		g.expr(it.cond)
		g.writeln(';')
		i := if it.key_var in ['', '_'] { g.new_tmp_var() } else { it.key_var }
		op_field := if cond_type_is_ptr { '->' } else { '.' }
		g.writeln('for (int $i = 0; $i < $atmp${op_field}len; ++$i) {')
		if it.val_var != '_' {
			g.writeln('\t$styp ${c_name(it.val_var)} = (($styp*)$atmp${op_field}data)[$i];')
		}
		g.stmts(it.stmts)
		g.writeln('}')
	} else if it.kind == .map {
		// `for key, val in map {`
		g.writeln('// FOR IN map')
		key_styp := g.typ(it.key_type)
		val_styp := g.typ(it.val_type)
		keys_tmp := 'keys_' + g.new_tmp_var()
		idx := g.new_tmp_var()
		key := if it.key_var in ['', '_'] { g.new_tmp_var() } else { it.key_var }
		zero := g.type_default(it.val_type)
		atmp := g.new_tmp_var()
		atmp_styp := g.typ(it.cond_type)
		g.write('$atmp_styp $atmp = ')
		g.expr(it.cond)
		g.writeln(';')
		g.writeln('array_$key_styp $keys_tmp = map_keys(&$atmp);')
		g.writeln('for (int $idx = 0; $idx < ${keys_tmp}.len; ++$idx) {')
		// TODO: analyze whether it.key_type has a .clone() method and call .clone() for all types:
		if it.key_type == table.string_type {
			g.writeln('\t$key_styp $key = /*kkkk*/ string_clone( (($key_styp*)${keys_tmp}.data)[$idx] );')
		} else {
			g.writeln('\t$key_styp $key = /*kkkk*/ (($key_styp*)${keys_tmp}.data)[$idx];')
		}
		if it.val_var != '_' {
			g.write('\t$val_styp ${c_name(it.val_var)} = /*vvv*/ (*($val_styp*)map_get($atmp')
			g.writeln(', $key, &($val_styp[]){ $zero }));')
		}
		g.stmts(it.stmts)
		g.writeln('}')
		g.writeln('/*for in map cleanup*/')
		g.writeln('for (int $idx = 0; $idx < ${keys_tmp}.len; ++$idx) { string_free(&(($key_styp*)${keys_tmp}.data)[$idx]); }')
		g.writeln('array_free(&$keys_tmp);')
	} else if it.cond_type.has_flag(.variadic) {
		g.writeln('// FOR IN cond_type/variadic')
		i := if it.key_var in ['', '_'] { g.new_tmp_var() } else { it.key_var }
		styp := g.typ(it.cond_type)
		g.write('for (int $i = 0; $i < ')
		g.expr(it.cond)
		g.writeln('.len; ++$i) {')
		g.write('\t$styp ${c_name(it.val_var)} = ')
		g.expr(it.cond)
		g.writeln('.args[$i];')
		g.stmts(it.stmts)
		g.writeln('}')
	} else if it.kind == .string {
		i := if it.key_var in ['', '_'] { g.new_tmp_var() } else { it.key_var }
		g.write('for (int $i = 0; $i < ')
		g.expr(it.cond)
		g.writeln('.len; ++$i) {')
		if it.val_var != '_' {
			g.write('\tbyte ${c_name(it.val_var)} = ')
			g.expr(it.cond)
			g.writeln('.str[$i];')
		}
		g.stmts(it.stmts)
		g.writeln('}')
	}
}

// use instead of expr() when you need to cast to sum type (can add other casts also)
fn (mut g Gen) expr_with_cast(expr ast.Expr, got_type, expected_type table.Type) {
	// cast to sum type
	if expected_type != table.void_type {
		if g.table.sumtype_has_variant(expected_type, got_type) {
			got_sym := g.table.get_type_symbol(got_type)
			got_styp := g.typ(got_type)
			exp_styp := g.typ(expected_type)
			got_idx := got_type.idx()
			if got_type.is_ptr() {
				g.write('/* sum type cast */ ($exp_styp) {.obj = ')
				g.expr(expr)
				g.write(', .typ = $got_idx /* $got_sym.name */}')
			} else {
				g.write('/* sum type cast */ ($exp_styp) {.obj = memdup(&($got_styp[]) {')
				g.expr(expr)
				g.write('}, sizeof($got_styp)), .typ = $got_idx /* $got_sym.name */}')
			}
			return
		}
	}
	// Generic dereferencing logic
	expected_sym := g.table.get_type_symbol(expected_type)
	got_is_ptr := got_type.is_ptr()
	expected_is_ptr := expected_type.is_ptr()
	neither_void := table.voidptr_type !in [got_type, expected_type]
	if got_is_ptr && !expected_is_ptr && neither_void &&
		expected_sym.kind !in [.interface_, .placeholder] {
		got_deref_type := got_type.deref()
		deref_sym := g.table.get_type_symbol(got_deref_type)
		deref_will_match := expected_type in [got_type, got_deref_type, deref_sym.parent_idx]
		got_is_opt := got_type.has_flag(.optional)
		if deref_will_match || got_is_opt {
			g.write('*')
		}
	}
	// no cast
	g.expr(expr)
}

// cestring returns a V string, properly escaped for embeddeding in a C string literal.
fn cestring(s string) string {
	return s.replace('\\', '\\\\').replace('"', "\'")
}

// ctoslit returns a 'tos_lit("$s")' call, where s is properly escaped.
fn ctoslit(s string) string {
	return 'tos_lit("' + cestring(s) + '")'
}

fn (mut g Gen) gen_assert_stmt(a ast.AssertStmt) {
	g.writeln('// assert')
	g.inside_ternary++
	g.write('if (')
	g.expr(a.expr)
	g.write(')')
	g.decrement_inside_ternary()
	if g.is_test {
		g.writeln('{')
		g.writeln('\tg_test_oks++;')
		metaname_ok := g.gen_assert_metainfo(a)
		g.writeln('\tmain__cb_assertion_ok(&$metaname_ok);')
		g.writeln('} else {')
		g.writeln('\tg_test_fails++;')
		metaname_fail := g.gen_assert_metainfo(a)
		g.writeln('\tmain__cb_assertion_failed(&$metaname_fail);')
		g.writeln('\tlongjmp(g_jump_buffer, 1);')
		g.writeln('\t// TODO')
		g.writeln('\t// Maybe print all vars in a test function if it fails?')
		g.writeln('}')
		return
	}
	g.writeln(' {} else {')
	metaname_panic := g.gen_assert_metainfo(a)
	g.writeln('\t__print_assert_failure(&$metaname_panic);')
	g.writeln('\tv_panic(tos_lit("Assertion failed..."));')
	g.writeln('\texit(1);')
	g.writeln('}')
}

fn (mut g Gen) gen_assert_metainfo(a ast.AssertStmt) string {
	mod_path := cestring(g.file.path)
	fn_name := g.fn_decl.name
	line_nr := a.pos.line_nr
	src := cestring(a.expr.str())
	metaname := 'v_assert_meta_info_$g.new_tmp_var()'
	g.writeln('\tVAssertMetaInfo $metaname;')
	g.writeln('\tmemset(&$metaname, 0, sizeof(VAssertMetaInfo));')
	g.writeln('\t${metaname}.fpath = ${ctoslit(mod_path)};')
	g.writeln('\t${metaname}.line_nr = $line_nr;')
	g.writeln('\t${metaname}.fn_name = ${ctoslit(fn_name)};')
	g.writeln('\t${metaname}.src = ${ctoslit(src)};')
	match a.expr {
		ast.InfixExpr {
			g.writeln('\t${metaname}.op = ${ctoslit(it.op.str())};')
			g.writeln('\t${metaname}.llabel = ${ctoslit(it.left.str())};')
			g.writeln('\t${metaname}.rlabel = ${ctoslit(it.right.str())};')
			g.write('\t${metaname}.lvalue = ')
			g.gen_assert_single_expr(it.left, it.left_type)
			g.writeln(';')
			//
			g.write('\t${metaname}.rvalue = ')
			g.gen_assert_single_expr(it.right, it.right_type)
			g.writeln(';')
		}
		ast.CallExpr {
			g.writeln('\t${metaname}.op = tos_lit("call");')
		}
		else {}
	}
	return metaname
}

fn (mut g Gen) gen_assert_single_expr(e ast.Expr, t table.Type) {
	unknown_value := '*unknown value*'
	match e {
		ast.CallExpr {
			g.write(ctoslit(unknown_value))
		}
		ast.CastExpr {
			g.write(ctoslit(unknown_value))
		}
		ast.IndexExpr {
			g.write(ctoslit(unknown_value))
		}
		ast.PrefixExpr {
			g.write(ctoslit(unknown_value))
		}
		ast.MatchExpr {
			g.write(ctoslit(unknown_value))
		}
		ast.Type {
			sym := g.table.get_type_symbol(t)
			g.write(ctoslit('$sym.name'))
		}
		else {
			g.gen_expr_to_string(e, t) or {
				g.write(ctoslit('[$err]'))
			}
		}
	}
	g.write(' /* typeof: ' + typeof(e) + ' type: ' + t.str() + ' */ ')
}

fn (mut g Gen) gen_assign_stmt(assign_stmt ast.AssignStmt) {
	if assign_stmt.is_static {
		g.write('static ')
	}
	mut return_type := table.void_type
	op := if assign_stmt.op == .decl_assign { token.Kind.assign } else { assign_stmt.op }
	is_decl := assign_stmt.op == .decl_assign
	match assign_stmt.right[0] {
		ast.CallExpr { return_type = it.return_type }
		ast.IfExpr { return_type = it.typ }
		ast.MatchExpr { return_type = it.return_type }
		else {}
	}
	// json_test failed w/o this check
	if return_type != table.void_type && return_type != 0 {
		sym := g.table.get_type_symbol(return_type)
		if sym.kind == .multi_return {
			// multi return
			// TODO Handle in if_expr
			is_optional := return_type.has_flag(.optional)
			mr_var_name := 'mr_$assign_stmt.pos.pos'
			mr_styp := g.typ(return_type)
			g.write('$mr_styp $mr_var_name = ')
			g.is_assign_rhs = true
			g.expr(assign_stmt.right[0])
			g.is_assign_rhs = false
			g.writeln(';')
			for i, lx in assign_stmt.left {
				match lx {
					ast.Ident {
						if lx.kind == .blank_ident {
							continue
						}
					}
					else {}
				}
				styp := g.typ(assign_stmt.left_types[i])
				if assign_stmt.op == .decl_assign {
					g.write('$styp ')
				}
				g.expr(lx)
				if is_optional {
					mr_base_styp := g.base_type(return_type)
					g.writeln(' = (*($mr_base_styp*)${mr_var_name}.data).arg$i;')
				} else {
					g.writeln(' = ${mr_var_name}.arg$i;')
				}
			}
			return
		}
	}
	// TODO: non idents on left (exprs)
	if assign_stmt.has_cross_var {
		for i, left in assign_stmt.left {
			match left {
				ast.Ident {
					var_type := assign_stmt.left_types[i]
					left_sym := g.table.get_type_symbol(var_type)
					if left_sym.kind == .function {
						func := left_sym.info as table.FnType
						ret_styp := g.typ(func.func.return_type)
						g.write('$ret_styp (*_var_$left.pos.pos) (')
						arg_len := func.func.args.len
						for j, arg in func.func.args {
							arg_type := g.table.get_type_symbol(arg.typ)
							g.write('$arg_type.str() $arg.name')
							if j < arg_len - 1 {
								g.write(', ')
							}
						}
						g.writeln(') = $left.name;')
					} else {
						styp := g.typ(var_type)
						g.writeln('$styp _var_$left.pos.pos = $left.name;')
					}
				}
				ast.IndexExpr {
					sym := g.table.get_type_symbol(left.left_type)
					if sym.kind == .array {
						info := sym.info as table.Array
						styp := g.typ(info.elem_type)
						g.write('$styp _var_$left.pos.pos = *($styp*)array_get(')
						if left.left_type.is_ptr() {
							g.write('*')
						}
						g.expr(left.left)
						g.write(', ')
						g.expr(left.index)
						g.writeln(');')
					} else if sym.kind == .map {
						info := sym.info as table.Map
						styp := g.typ(info.value_type)
						zero := g.type_default(info.value_type)
						g.write('$styp _var_$left.pos.pos = *($styp*)map_get(')
						if left.left_type.is_ptr() {
							g.write('*')
						}
						g.expr(left.left)
						g.write(', ')
						g.expr(left.index)
						g.writeln(', &($styp[]){ $zero });')
					}
				}
				ast.SelectorExpr {
					styp := g.typ(left.typ)
					g.write('$styp _var_$left.pos.pos = ')
					g.expr(left.expr)
					if left.expr_type.is_ptr() {
						g.writeln('->$left.field_name;')
					} else {
						g.writeln('.$left.field_name;')
					}
				}
				else {}
			}
		}
	}
	// `a := 1` | `a,b := 1,2`
	for i, left in assign_stmt.left {
		mut var_type := assign_stmt.left_types[i]
		mut val_type := assign_stmt.right_types[i]
		val := assign_stmt.right[i]
		mut is_call := false
		mut blank_assign := false
		mut ident := ast.Ident{}
		if left is ast.Ident {
			ident = *left
			// id_info := ident.var_info()
			// var_type = id_info.typ
			blank_assign = left.kind == .blank_ident
			if left.info is ast.IdentVar {
				share := (left.info as ast.IdentVar).share
				if share == .shared_t {
					var_type = var_type.set_flag(.shared_f)
				}
				if share == .atomic_t {
					var_type = var_type.set_flag(.atomic_f)
				}
			}
		}
		styp := g.typ(var_type)
		mut is_fixed_array_init := false
		mut has_val := false
		match val {
			ast.ArrayInit {
				is_fixed_array_init = val.is_fixed
				has_val = val.has_val
			}
			ast.CallExpr {
				is_call = true
				return_type = val.return_type
			}
			// TODO: no buffer fiddling
			ast.AnonFn {
				if blank_assign {
					g.write('{')
				}
				ret_styp := g.typ(val.decl.return_type)
				g.write('$ret_styp (*$ident.name) (')
				def_pos := g.definitions.len
				g.fn_args(val.decl.args, val.decl.is_variadic)
				g.definitions.go_back(g.definitions.len - def_pos)
				g.write(') = ')
				g.expr(*val)
				g.writeln(';')
				if blank_assign {
					g.write('}')
				}
				continue
			}
			else {}
		}
		right_sym := g.table.get_type_symbol(val_type)
		g.is_assign_lhs = true
		if val_type.has_flag(.optional) {
			g.right_is_opt = true
		}
		if blank_assign {
			if is_call {
				g.expr(val)
			} else {
				g.write('{$styp _ = ')
				g.expr(val)
				g.writeln(';}')
			}
		} else if right_sym.kind == .array_fixed && assign_stmt.op == .assign {
			right := val as ast.ArrayInit
			for j, expr in right.exprs {
				g.expr(left)
				g.write('[$j] = ')
				g.expr(expr)
				g.writeln(';')
			}
		} else {
			g.assign_op = assign_stmt.op
			is_inside_ternary := g.inside_ternary != 0
			cur_line := if is_inside_ternary && is_decl {
				g.register_ternary_name(ident.name)
				g.empty_line = false
				g.go_before_ternary()
			} else {
				''
			}
			mut str_add := false
			if var_type == table.string_type_idx && assign_stmt.op == .plus_assign {
				if left is ast.IndexExpr {
					// a[0] += str => `array_set(&a, 0, &(string[]) {string_add(...))})`
					g.expr(left)
					g.write('string_add(')
				} else {
					// str += str2 => `str = string_add(str, str2)`
					g.expr(left)
					g.write(' = /*f*/string_add(')
				}
				g.is_assign_lhs = false
				g.is_assign_rhs = true
				str_add = true
			}
			if right_sym.kind == .function && is_decl {
				if is_inside_ternary && is_decl {
					g.out.write(tabs[g.indent - g.inside_ternary])
				}
				func := right_sym.info as table.FnType
				ret_styp := g.typ(func.func.return_type)
				g.write('$ret_styp (*${g.get_ternary_name(ident.name)}) (')
				def_pos := g.definitions.len
				g.fn_args(func.func.args, func.func.is_variadic)
				g.definitions.go_back(g.definitions.len - def_pos)
				g.write(')')
			} else {
				if is_decl {
					if is_inside_ternary {
						g.out.write(tabs[g.indent - g.inside_ternary])
					}
					g.write('$styp ')
				}
				g.expr(left)
			}
			if is_inside_ternary && is_decl {
				g.write(';\n$cur_line')
				g.out.write(tabs[g.indent])
				g.expr(left)
			}
			g.is_assign_lhs = false
			g.is_assign_rhs = true
			if !g.is_array_set && !str_add {
				g.write(' $op ')
			} else if str_add {
				g.write(', ')
			}
			mut cloned := false
			if g.autofree && right_sym.kind in [.array, .string] {
				if g.gen_clone_assignment(val, right_sym, false) {
					cloned = true
				}
			}
			unwrap_optional := !var_type.has_flag(.optional) && val_type.has_flag(.optional)
			if unwrap_optional {
				g.write('*($styp*)')
			}
			g.is_shared = var_type.has_flag(.shared_f)
			if !cloned {
				if is_decl {
					if is_fixed_array_init && !has_val {
						g.write('{0}')
					} else {
						g.expr(val)
					}
				} else {
					if assign_stmt.has_cross_var {
						g.gen_cross_tmp_variable(assign_stmt.left, val)
					} else {
						g.expr_with_cast(val, val_type, var_type)
					}
				}
			}
			if unwrap_optional {
				g.write('.data')
			}
			if str_add {
				g.write(')')
			}
			if g.is_array_set {
				g.write(' })')
				g.is_array_set = false
			}
			g.is_shared = false
		}
		g.right_is_opt = false
		g.is_assign_rhs = false
		if g.inside_ternary == 0 && !assign_stmt.is_simple {
			g.writeln(';')
		}
	}
}

fn (mut g Gen) gen_cross_tmp_variable(left []ast.Expr, val ast.Expr) {
	val_ := val
	match val {
		ast.Ident {
			mut has_var := false
			for lx in left {
				if lx is ast.Ident {
					if val.name == lx.name {
						g.write('_var_')
						g.write(lx.pos.pos.str())
						has_var = true
						break
					}
				}
			}
			if !has_var {
				g.expr(val_)
			}
		}
		ast.IndexExpr {
			mut has_var := false
			for lx in left {
				if val_.str() == lx.str() {
					g.write('_var_')
					g.write(lx.position().pos.str())
					has_var = true
					break
				}
			}
			if !has_var {
				g.expr(val_)
			}
		}
		ast.InfixExpr {
			g.gen_cross_tmp_variable(left, val.left)
			g.write(val.op.str())
			g.gen_cross_tmp_variable(left, val.right)
		}
		ast.PrefixExpr {
			g.write(val.op.str())
			g.gen_cross_tmp_variable(left, val.right)
		}
		ast.PostfixExpr {
			g.gen_cross_tmp_variable(left, val.expr)
			g.write(val.op.str())
		}
		ast.SelectorExpr {
			mut has_var := false
			for lx in left {
				if val_.str() == lx.str() {
					g.write('_var_')
					g.write(lx.position().pos.str())
					has_var = true
					break
				}
			}
			if !has_var {
				g.expr(val_)
			}
		}
		else {
			g.expr(val_)
		}
	}
}

fn (mut g Gen) register_ternary_name(name string) {
	level_key := g.inside_ternary.str()
	if level_key !in g.ternary_level_names {
		g.ternary_level_names[level_key] = []string{}
	}
	new_name := g.new_tmp_var()
	g.ternary_names[name] = new_name
	g.ternary_level_names[level_key] << name
}

fn (mut g Gen) get_ternary_name(name string) string {
	if g.inside_ternary == 0 {
		return name
	}
	if name !in g.ternary_names {
		return name
	}
	return g.ternary_names[name]
}

fn (mut g Gen) gen_clone_assignment(val ast.Expr, right_sym table.TypeSymbol, add_eq bool) bool {
	mut is_ident := false
	match val {
		ast.Ident { is_ident = true }
		ast.SelectorExpr { is_ident = true }
		else { return false }
	}
	if g.autofree && right_sym.kind == .array && is_ident {
		// `arr1 = arr2` => `arr1 = arr2.clone()`
		if add_eq {
			g.write('=')
		}
		g.write(' array_clone_static(')
		g.expr(val)
		g.write(')')
	} else if g.autofree && right_sym.kind == .string && is_ident {
		if add_eq {
			g.write('=')
		}
		// `str1 = str2` => `str1 = str2.clone()`
		g.write(' string_clone_static(')
		g.expr(val)
		g.write(')')
	}
	return true
}

fn (mut g Gen) autofree_scope_vars(pos int) {
	g.writeln('// autofree_scope_vars($pos)')
	// eprintln('> free_scope_vars($pos)')
	scope := g.file.scope.innermost(pos)
	for _, obj in scope.objects {
		match obj {
			ast.Var {
				// if var.typ == 0 {
				// // TODO why 0?
				// continue
				// }
				v := *obj
				is_optional := v.typ.has_flag(.optional)
				if is_optional {
					// TODO: free optionals
					continue
				}
				g.autofree_variable(v)
			}
			else {}
		}
	}
}

fn (g &Gen) autofree_variable(v ast.Var) {
	sym := g.table.get_type_symbol(v.typ)
	// if v.name.contains('output2') {
	// eprintln('   > var name: ${v.name:-20s} | is_arg: ${v.is_arg.str():6} | var type: ${int(v.typ):8} | type_name: ${sym.name:-33s}')
	// }
	if sym.kind == .array {
		g.autofree_var_call('array_free', v)
		return
	}
	if sym.kind == .string {
		// Don't free simple string literals.
		match v.expr {
			ast.StringLiteral {
				g.writeln('// str literal')
			}
			else {
				// NOTE/TODO: assign_stmt multi returns variables have no expr
				// since the type comes from the called fns return type
				/*
				f := v.name[0]
				if
					//!(f >= `a` && f <= `d`) {
					//f != `c` {
					v.name!='cvar_name' {
					t := typeof(v.expr)
				return '// other ' + t + '\n'
				}
				*/
			}
		}
		g.autofree_var_call('string_free', v)
		return
	}
	if sym.has_method('free') {
		g.autofree_var_call(c_name(sym.name) + '_free', v)
	}
}

fn (g &Gen) autofree_var_call(free_fn_name string, v ast.Var) {
	if v.is_arg {
		// fn args should not be autofreed
		return
	}
	if v.typ.is_ptr() {
		g.writeln('\t${free_fn_name}(${c_name(v.name)}); // autofreed ptr var')
	} else {
		g.writeln('\t${free_fn_name}(&${c_name(v.name)}); // autofreed var')
	}
}

fn (mut g Gen) gen_anon_fn_decl(it ast.AnonFn) {
	pos := g.out.len
	def_pos := g.definitions.len
	g.stmt(it.decl)
	fn_body := g.out.after(pos)
	g.out.go_back(fn_body.len)
	g.definitions.go_back(g.definitions.len - def_pos)
	g.definitions.write(fn_body)
}

fn (mut g Gen) expr(node ast.Expr) {
	// println('cgen expr() line_nr=$node.pos.line_nr')
	match node {
		ast.AnonFn {
			// TODO: dont fiddle with buffers
			g.gen_anon_fn_decl(node)
			fsym := g.table.get_type_symbol(node.typ)
			g.write(fsym.name)
		}
		ast.ArrayInit {
			g.array_init(node)
		}
		ast.AsCast {
			g.as_cast(node)
		}
		ast.Assoc {
			g.assoc(node)
		}
		ast.BoolLiteral {
			g.write(node.val.str())
		}
		ast.CallExpr {
			g.call_expr(node)
		}
		ast.CastExpr {
			// g.write('/*cast*/')
			if g.is_amp {
				// &Foo(0) => ((Foo*)0)
				g.out.go_back(1)
			}
			sym := g.table.get_type_symbol(node.typ)
			if sym.kind == .string && !node.typ.is_ptr() {
				// `string(x)` needs `tos()`, but not `&string(x)
				// `tos(str, len)`, `tos2(str)`
				if node.has_arg {
					g.write('tos((byteptr)')
				} else {
					g.write('tos2((byteptr)')
				}
				g.expr(node.expr)
				expr_sym := g.table.get_type_symbol(node.expr_type)
				if expr_sym.kind == .array {
					// if we are casting an array, we need to add `.data`
					g.write('.data')
				}
				if node.has_arg {
					// len argument
					g.write(', ')
					g.expr(node.arg)
				}
				g.write(')')
			} else if sym.kind == .sum_type {
				g.expr_with_cast(node.expr, node.expr_type, node.typ)
			} else {
				// styp := g.table.Type_to_str(it.typ)
				styp := g.typ(node.typ)
				// g.write('($styp)(')
				g.write('(($styp)(')
				// if g.is_amp {
				// g.write('*')
				// }
				// g.write(')(')
				g.expr(node.expr)
				g.write('))')
			}
		}
		ast.CharLiteral {
			g.write("'$node.val'")
		}
		ast.ComptimeCall {
			g.comptime_call(node)
		}
		ast.Comment {}
		ast.ConcatExpr {
			g.concat_expr(node)
		}
		ast.EnumVal {
			// g.write('${it.mod}${it.enum_name}_$it.val')
			styp := g.typ(node.typ)
			g.write('${styp}_$node.val')
		}
		ast.FloatLiteral {
			g.write(node.val)
		}
		ast.Ident {
			g.ident(node)
		}
		ast.IfExpr {
			g.if_expr(node)
		}
		ast.IfGuardExpr {
			g.write('/* guard */')
		}
		ast.IndexExpr {
			g.index_expr(node)
		}
		ast.InfixExpr {
			if node.op in [.left_shift, .plus_assign, .minus_assign] {
				g.inside_map_infix = true
				g.infix_expr(node)
				g.inside_map_infix = false
			} else {
				g.infix_expr(node)
			}
		}
		ast.IntegerLiteral {
			if node.val.starts_with('0o') {
				g.write('0')
				g.write(node.val[2..])
			} else {
				g.write(node.val) // .int().str())
			}
		}
		ast.LockExpr {
			g.lock_expr(node)
		}
		ast.MatchExpr {
			g.match_expr(node)
		}
		ast.MapInit {
			key_typ_str := g.typ(node.key_type)
			value_typ_str := g.typ(node.value_type)
			size := node.vals.len
			if size > 0 {
				g.write('new_map_init($size, sizeof($value_typ_str), _MOV(($key_typ_str[$size]){')
				for expr in node.keys {
					g.expr(expr)
					g.write(', ')
				}
				g.write('}), _MOV(($value_typ_str[$size]){')
				for expr in node.vals {
					g.expr(expr)
					g.write(', ')
				}
				g.write('}))')
			} else {
				g.write('new_map_1(sizeof($value_typ_str))')
			}
		}
		ast.None {
			g.write('opt_none()')
		}
		ast.OrExpr {
			// this should never appear here
		}
		ast.ParExpr {
			g.write('(')
			g.expr(node.expr)
			g.write(')')
		}
		ast.PostfixExpr {
			if node.auto_locked != '' {
				g.writeln('sync__RwMutex_w_lock($node.auto_locked->mtx);')
			}
			g.inside_map_postfix = true
			g.expr(node.expr)
			g.inside_map_postfix = false
			g.write(node.op.str())
			if node.auto_locked != '' {
				g.writeln(';')
				g.write('sync__RwMutex_w_unlock($node.auto_locked->mtx)')
			}
		}
		ast.PrefixExpr {
			if node.op == .amp {
				g.is_amp = true
			}
			// g.write('/*pref*/')
			g.write(node.op.str())
			// g.write('(')
			g.expr(node.right)
			// g.write(')')
			g.is_amp = false
		}
		ast.RangeExpr {
			// Only used in IndexExpr
		}
		ast.SizeOf {
			if node.is_type {
				node_typ := g.unwrap_generic(node.typ)
				mut styp := node.type_name
				if styp.starts_with('C.') {
					styp = styp[2..]
				}
				if node.type_name == '' || node.typ.has_flag(.generic) {
					styp = g.typ(node_typ)
				} else {
					sym := g.table.get_type_symbol(node_typ)
					if sym.kind == .struct_ {
						info := sym.info as table.Struct
						if !info.is_typedef {
							styp = 'struct ' + styp
						}
					}
				}
				g.write('/*SizeOfType*/ sizeof(${util.no_dots(styp)})')
			} else {
				g.write('/*SizeOfVar*/ sizeof(')
				g.expr(node.expr)
				g.write(')')
			}
		}
		ast.SqlExpr {
			g.sql_select_expr(node)
		}
		ast.StringLiteral {
			g.string_literal(node)
		}
		ast.StringInterLiteral {
			g.string_inter_literal(node)
		}
		ast.StructInit {
			// `user := User{name: 'Bob'}`
			g.struct_init(node)
		}
		ast.SelectorExpr {
			g.expr(node.expr)
			if node.expr_type.is_ptr() {
				g.write('->')
			} else {
				// g.write('. /*typ=  $it.expr_type */') // ${g.typ(it.expr_type)} /')
				g.write('.')
			}
			if node.expr_type.has_flag(.shared_f) {
				g.write('val.')
			}
			if node.expr_type == 0 {
				verror('cgen: SelectorExpr | expr_type: 0 | it.expr: `$node.expr` | field: `$node.field_name` | file: $g.file.path | line: $node.pos.line_nr')
			}
			g.write(c_name(node.field_name))
		}
		ast.Type {
			// match sum Type
			// g.write('/* Type */')
			type_idx := node.typ.idx()
			sym := g.table.get_type_symbol(node.typ)
			g.write('$type_idx /* $sym.name */')
		}
		ast.TypeOf {
			g.typeof_expr(node)
		}
		ast.Likely {
			if node.is_likely {
				g.write('_likely_')
			} else {
				g.write('_unlikely_')
			}
			g.write('(')
			g.expr(node.expr)
			g.write(')')
		}
		ast.UnsafeExpr {
			es := node.stmts[0] as ast.ExprStmt
			g.expr(es.expr)
		}
	}
}

fn (mut g Gen) typeof_expr(node ast.TypeOf) {
	sym := g.table.get_type_symbol(node.expr_type)
	if sym.kind == .sum_type {
		// When encountering a .sum_type, typeof() should be done at runtime,
		// because the subtype of the expression may change:
		sum_type_idx := node.expr_type.idx()
		g.write('tos3( /* $sym.name */ v_typeof_sumtype_${sum_type_idx}( (')
		g.expr(node.expr)
		g.write(').typ ))')
	} else if sym.kind == .array_fixed {
		fixed_info := sym.info as table.ArrayFixed
		typ_name := g.table.get_type_name(fixed_info.elem_type)
		g.write('tos_lit("[$fixed_info.size]${util.strip_main_name(typ_name)}")')
	} else if sym.kind == .function {
		info := sym.info as table.FnType
		fn_info := info.func
		mut repr := 'fn ('
		for i, arg in fn_info.args {
			if i > 0 {
				repr += ', '
			}
			repr += util.strip_main_name(g.table.get_type_name(arg.typ))
		}
		repr += ')'
		if fn_info.return_type != table.void_type {
			repr += ' ${util.strip_main_name(g.table.get_type_name(fn_info.return_type))}'
		}
		g.write('tos_lit("$repr")')
	} else {
		g.write('tos_lit("${util.strip_main_name(sym.name)}")')
	}
}

fn (mut g Gen) enum_expr(node ast.Expr) {
	match node {
		ast.EnumVal { g.write(node.val) }
		else { g.expr(node) }
	}
}

fn (mut g Gen) infix_expr(node ast.InfixExpr) {
	// println('infix_expr() op="$node.op.str()" line_nr=$node.pos.line_nr')
	// g.write('/*infix*/')
	// if it.left_type == table.string_type_idx {
	// g.write('/*$node.left_type str*/')
	// }
	// string + string, string == string etc
	// g.infix_op = node.op
	if node.auto_locked != '' {
		g.writeln('sync__RwMutex_w_lock($node.auto_locked->mtx);')
	}
	left_type := g.unwrap_generic(node.left_type)
	left_sym := g.table.get_type_symbol(left_type)
	unaliased_left := if left_sym.kind == .alias { (left_sym.info as table.Alias).parent_type } else { left_type }
	if node.op in [.key_is, .not_is] {
		g.is_expr(node)
		return
	}
	right_sym := g.table.get_type_symbol(node.right_type)
	unaliased_right := if right_sym.kind == .alias { (right_sym.info as table.Alias).parent_type } else { node.right_type }
	if left_type == table.ustring_type_idx && node.op != .key_in && node.op != .not_in {
		fn_name := match node.op {
			.plus {
				'ustring_add('
			}
			.eq {
				'ustring_eq('
			}
			.ne {
				'ustring_ne('
			}
			.lt {
				'ustring_lt('
			}
			.le {
				'ustring_le('
			}
			.gt {
				'ustring_gt('
			}
			.ge {
				'ustring_ge('
			}
			else {
				verror('op error for type `$left_sym.name`')
				'/*node error*/'
			}
		}
		g.write(fn_name)
		g.expr(node.left)
		g.write(', ')
		g.expr(node.right)
		g.write(')')
	} else if left_type == table.string_type_idx && node.op != .key_in && node.op != .not_in {
		fn_name := match node.op {
			.plus {
				'string_add('
			}
			.eq {
				'string_eq('
			}
			.ne {
				'string_ne('
			}
			.lt {
				'string_lt('
			}
			.le {
				'string_le('
			}
			.gt {
				'string_gt('
			}
			.ge {
				'string_ge('
			}
			else {
				verror('op error for type `$left_sym.name`')
				'/*node error*/'
			}
		}
		g.write(fn_name)
		g.expr(node.left)
		g.write(', ')
		g.expr(node.right)
		g.write(')')
	} else if node.op in [.eq, .ne] && left_sym.kind == .array && right_sym.kind == .array {
		ptr_typ := g.gen_array_equality_fn(left_type)
		if node.op == .eq {
			g.write('${ptr_typ}_arr_eq(')
		} else if node.op == .ne {
			g.write('!${ptr_typ}_arr_eq(')
		}
		if node.left_type.is_ptr() {
			g.write('*')
		}
		g.expr(node.left)
		g.write(', ')
		if node.right_type.is_ptr() {
			g.write('*')
		}
		g.expr(node.right)
		g.write(')')
	} else if node.op in [.eq, .ne] && left_sym.kind == .map && right_sym.kind == .map {
		ptr_typ := g.gen_map_equality_fn(left_type)
		if node.op == .eq {
			g.write('${ptr_typ}_map_eq(')
		} else if node.op == .ne {
			g.write('!${ptr_typ}_map_eq(')
		}
		if node.left_type.is_ptr() {
			g.write('*')
		}
		g.expr(node.left)
		g.write(', ')
		if node.right_type.is_ptr() {
			g.write('*')
		}
		g.expr(node.right)
		g.write(')')
	} else if node.op in [.key_in, .not_in] {
		if node.op == .not_in {
			g.write('!')
		}
		if right_sym.kind == .array {
			match node.right {
				ast.ArrayInit {
					if it.exprs.len > 0 {
						// `a in [1,2,3]` optimization => `a == 1 || a == 2 || a == 3`
						// avoids an allocation
						// g.write('/*in opt*/')
						g.write('(')
						g.in_optimization(node.left, it)
						g.write(')')
						return
					}
				}
				else {}
			}
			styp := g.typ(g.table.mktyp(left_type))
			g.write('_IN($styp, ')
			g.expr(node.left)
			g.write(', ')
			if node.right_type.is_ptr() {
				g.write('*')
			}
			g.expr(node.right)
			g.write(')')
		} else if right_sym.kind == .map {
			g.write('_IN_MAP(')
			g.expr(node.left)
			g.write(', ')
			if node.right_type.is_ptr() {
				g.write('*')
			}
			g.expr(node.right)
			g.write(')')
		} else if right_sym.kind == .string {
			g.write('string_contains(')
			g.expr(node.right)
			g.write(', ')
			g.expr(node.left)
			g.write(')')
		}
	} else if node.op == .left_shift && left_sym.kind == .array {
		// arr << val
		tmp := g.new_tmp_var()
		info := left_sym.info as table.Array
		if right_sym.kind == .array && info.elem_type != node.right_type {
			// push an array => PUSH_MANY, but not if pushing an array to 2d array (`[][]int << []int`)
			g.write('_PUSH_MANY(&')
			g.expr(node.left)
			g.write(', (')
			g.expr_with_cast(node.right, node.right_type, left_type)
			styp := g.typ(left_type)
			g.write('), $tmp, $styp)')
		} else {
			// push a single element
			elem_type_str := g.typ(info.elem_type)
			g.write('array_push(')
			if !left_type.is_ptr() {
				g.write('&')
			}
			g.expr(node.left)
			g.write(', _MOV(($elem_type_str[]){ ')
			elem_sym := g.table.get_type_symbol(info.elem_type)
			if elem_sym.kind == .interface_ && node.right_type != info.elem_type {
				g.interface_call(node.right_type, info.elem_type)
			}
			g.expr_with_cast(node.right, node.right_type, info.elem_type)
			if elem_sym.kind == .interface_ && node.right_type != info.elem_type {
				g.write(')')
			}
			g.write(' }))')
		}
	} else if unaliased_left.idx() in [table.u32_type_idx, table.u64_type_idx] && unaliased_right.is_signed() &&
		node.op in [.eq, .ne, .gt, .lt, .ge, .le] {
		bitsize := if unaliased_left.idx() == table.u32_type_idx &&
			unaliased_right.idx() != table.i64_type_idx { 32 } else { 64 }
		g.write('_us${bitsize}_${cmp_str[int(node.op)-int(token.Kind.eq)]}(')
		g.expr(node.left)
		g.write(',')
		g.expr(node.right)
		g.write(')')
	} else if unaliased_right.idx() in [table.u32_type_idx, table.u64_type_idx] && unaliased_left.is_signed() &&
		node.op in [.eq, .ne, .gt, .lt, .ge, .le] {
		bitsize := if unaliased_right.idx() == table.u32_type_idx &&
			unaliased_left.idx() != table.i64_type_idx { 32 } else { 64 }
		g.write('_us${bitsize}_${cmp_rev[int(node.op)-int(token.Kind.eq)]}(')
		g.expr(node.right)
		g.write(',')
		g.expr(node.left)
		g.write(')')
	} else {
		a := left_sym.name[0].is_capital() || left_sym.name.contains('.')
		b := left_sym.kind != .alias
		c := left_sym.kind == .alias && (left_sym.info as table.Alias).language == .c
		if node.op in [.plus, .minus, .mul, .div, .mod] && ((a && b) || c) {
			// Overloaded operators
			g.write(g.typ(left_type))
			g.write('_')
			g.write(util.replace_op(node.op.str()))
			g.write('(')
			g.expr(node.left)
			g.write(', ')
			g.expr(node.right)
			g.write(')')
		} else {
			need_par := node.op in [.amp, .pipe, .xor] // `x & y == 0` => `(x & y) == 0` in C
			if need_par {
				g.write('(')
			}
			g.expr(node.left)
			g.write(' $node.op.str() ')
			g.expr(node.right)
			if need_par {
				g.write(')')
			}
		}
	}
	if node.auto_locked != '' {
		g.writeln(';')
		g.write('sync__RwMutex_w_unlock($node.auto_locked->mtx)')
	}
}

fn (mut g Gen) lock_expr(node ast.LockExpr) {
	mut lock_prefixes := []byte{len: 0, cap: node.lockeds.len}
	for id in node.lockeds {
		name := id.name
		deref := if id.is_mut { '->' } else { '.' }
		lock_prefix := if node.is_rlock { `r` } else { `w` }
		lock_prefixes << lock_prefix // keep for unlock
		g.writeln('sync__RwMutex_${lock_prefix:c}_lock($name${deref}mtx);')
	}
	g.stmts(node.stmts)
	// unlock in reverse order
	for i := node.lockeds.len - 1; i >= 0; i-- {
		id := node.lockeds[i]
		lock_prefix := lock_prefixes[i]
		name := id.name
		deref := if id.is_mut { '->' } else { '.' }
		g.writeln('sync__RwMutex_${lock_prefix:c}_unlock($name${deref}mtx);')
	}
}

fn (mut g Gen) match_expr(node ast.MatchExpr) {
	// println('match expr typ=$it.expr_type')
	// TODO
	if node.cond_type == 0 {
		g.writeln('// match 0')
		return
	}
	is_expr := (node.is_expr && node.return_type != table.void_type) || g.inside_ternary > 0
	if is_expr {
		g.inside_ternary++
		// g.write('/* EM ret type=${g.typ(node.return_type)}		expected_type=${g.typ(node.expected_type)}  */')
	}
	type_sym := g.table.get_type_symbol(node.cond_type)
	mut tmp := ''
	if type_sym.kind != .void {
		tmp = g.new_tmp_var()
	}
	// styp := g.typ(node.expr_type)
	// g.write('$styp $tmp = ')
	// g.expr(node.cond)
	// g.writeln(';') // $it.blocks.len')
	// mut sum_type_str = ''
	for j, branch in node.branches {
		is_last := j == node.branches.len - 1
		if branch.is_else || (node.is_expr && is_last) {
			if node.branches.len > 1 {
				if is_expr {
					// TODO too many branches. maybe separate ?: matches
					g.write(' : ')
				} else {
					g.writeln(' else {')
				}
			}
		} else {
			if j > 0 {
				if is_expr {
					g.write(' : ')
				} else {
					g.write(' else ')
				}
			}
			if is_expr {
				g.write('(')
			} else {
				g.write('if (')
			}
			for i, expr in branch.exprs {
				if node.is_sum_type {
					g.expr(node.cond)
					sym := g.table.get_type_symbol(node.cond_type)
					// branch_sym := g.table.get_type_symbol(branch.typ)
					if sym.kind == .sum_type {
						g.write('.typ == ')
					} else if sym.kind == .interface_ {
						// g.write('._interface_idx == _${sym.name}_${branch_sym} ')
						g.write('._interface_idx == ')
					}
					g.expr(expr)
				} else if type_sym.kind == .string {
					g.write('string_eq(')
					//
					g.expr(node.cond)
					g.write(', ')
					// g.write('string_eq($tmp, ')
					g.expr(expr)
					g.write(')')
				} else if expr is ast.RangeExpr {
					g.write('(')
					g.expr(node.cond)
					g.write(' >= ')
					g.expr(expr.low)
					g.write(' && ')
					g.expr(node.cond)
					g.write(' <= ')
					g.expr(expr.high)
					g.write(')')
				} else {
					g.expr(node.cond)
					g.write(' == ')
					// g.write('$tmp == ')
					g.expr(expr)
				}
				if i < branch.exprs.len - 1 {
					g.write(' || ')
				}
			}
			if is_expr {
				g.write(') ? ')
			} else {
				g.writeln(') {')
			}
		}
		// g.writeln('/* M sum_type=$node.is_sum_type is_expr=$node.is_expr exp_type=${g.typ(node.expected_type)}*/')
		if node.is_sum_type && branch.exprs.len > 0 && !node.is_expr {
			// The first node in expr is an ast.Type
			// Use it to generate `it` variable.
			first_expr := branch.exprs[0]
			match first_expr {
				ast.Type {
					it_type := g.typ(first_expr.typ)
					// g.writeln('$it_type* it = ($it_type*)${tmp}.obj; // ST it')
					g.write('\t$it_type* it = ($it_type*)')
					g.expr(node.cond)
					g.writeln('.obj; // ST it')
					if node.var_name.len > 0 {
						// for now we just copy it
						g.writeln('\t$it_type* $node.var_name = it;')
					}
				}
				else {
					verror('match sum type')
				}
			}
		}
		g.stmts(branch.stmts)
		if g.inside_ternary == 0 && node.branches.len > 1 {
			g.write('}')
		}
	}
	if is_expr {
		g.decrement_inside_ternary()
	}
}

fn (mut g Gen) ident(node ast.Ident) {
	if node.name == 'lld' {
		return
	}
	if node.name.starts_with('C.') {
		g.write(util.no_dots(node.name[2..]))
		return
	}
	if node.kind == .constant { // && !node.name.starts_with('g_') {
		// TODO globals hack
		g.write('_const_')
	}
	mut name := c_name(node.name)
	if node.info is ast.IdentVar {
		ident_var := node.info as ast.IdentVar
		// x ?int
		// `x = 10` => `x.data = 10` (g.right_is_opt == false)
		// `x = new_opt()` => `x = new_opt()` (g.right_is_opt == true)
		// `println(x)` => `println(*(int*)x.data)`
		if ident_var.is_optional && !(g.is_assign_lhs && g.right_is_opt) {
			g.write('/*opt*/')
			styp := g.base_type(ident_var.typ)
			g.write('(*($styp*)${name}.data)')
			return
		}
		if !g.is_assign_lhs && ident_var.share == .shared_t {
			g.write('${name}.val')
			return
		}
	}
	g.write(g.get_ternary_name(name))
}

fn (mut g Gen) concat_expr(node ast.ConcatExpr) {
	styp := g.typ(node.return_type)
	sym := g.table.get_type_symbol(node.return_type)
	is_multi := sym.kind == .multi_return
	if !is_multi {
		g.expr(node.vals[0])
	} else {
		g.write('($styp){')
		for i, expr in node.vals {
			g.write('.arg$i=')
			g.expr(expr)
			if i < node.vals.len - 1 {
				g.write(',')
			}
		}
		g.write('}')
	}
}

fn (mut g Gen) if_expr(node ast.IfExpr) {
	if node.is_expr || g.inside_ternary != 0 {
		g.inside_ternary++
		g.write('(')
		for i, branch in node.branches {
			if i > 0 {
				g.write(' : ')
			}
			if i < node.branches.len - 1 || !node.has_else {
				g.expr(branch.cond)
				g.write(' ? ')
			}
			g.stmts(branch.stmts)
		}
		if node.branches.len == 1 {
			g.write(': 0')
		}
		g.write(')')
		g.decrement_inside_ternary()
		return
	}
	mut is_guard := false
	mut guard_idx := 0
	mut guard_vars := []string{}
	for i, branch in node.branches {
		cond := branch.cond
		if cond is ast.IfGuardExpr {
			if !is_guard {
				is_guard = true
				guard_idx = i
				guard_vars = []string{len: node.branches.len}
				g.writeln('{ /* if guard */ ')
			}
			var_name := g.new_tmp_var()
			guard_vars[i] = var_name
			g.writeln('${g.typ(cond.expr_type)} $var_name;')
		}
	}
	for i, branch in node.branches {
		if i > 0 {
			g.write('} else ')
		}
		// if last branch is `else {`
		if i == node.branches.len - 1 && node.has_else {
			g.writeln('{')
			// define `err` only for simple `if val := opt {...} else {`
			if is_guard && guard_idx == i - 1 {
				cvar_name := guard_vars[guard_idx]
				g.writeln('\tstring err = ${cvar_name}.v_error;')
				g.writeln('\tint errcode = ${cvar_name}.ecode;')
			}
		} else {
			match branch.cond as cond {
				ast.IfGuardExpr {
					var_name := guard_vars[i]
					g.write('if ($var_name = ')
					g.expr(it.expr)
					g.writeln(', ${var_name}.ok) {')
					if cond.var_name != '_' {
						g.writeln('\t${g.typ(cond.expr_type)} $cond.var_name = $var_name;')
					}
				}
				else {
					g.write('if (')
					g.expr(branch.cond)
					g.writeln(') {')
				}
			}
		}
		if branch.smartcast && branch.stmts.len > 0 {
			infix := branch.cond as ast.InfixExpr
			right_type := infix.right as ast.Type
			left_type := infix.left_type
			it_type := g.typ(right_type.typ)
			g.write('\t$it_type* _sc_tmp_$branch.pos.pos = ($it_type*)')
			g.expr(infix.left)
			if left_type.is_ptr() {
				g.write('->')
			} else {
				g.write('.')
			}
			g.writeln('obj;')
			g.writeln('\t$it_type* $branch.left_as_name = _sc_tmp_$branch.pos.pos;')
		}
		g.stmts(branch.stmts)
	}
	if is_guard {
		g.write('}')
	}
	g.writeln('}')
}

fn (mut g Gen) index_expr(node ast.IndexExpr) {
	match node.index {
		ast.RangeExpr {
			sym := g.table.get_type_symbol(node.left_type)
			if sym.kind == .string {
				g.write('string_substr(')
				g.expr(node.left)
			} else if sym.kind == .array {
				g.write('array_slice(')
				g.expr(node.left)
			} else if sym.kind == .array_fixed {
				// Convert a fixed array to V array when doing `fixed_arr[start..end]`
				g.write('array_slice(new_array_from_c_array(_ARR_LEN(')
				g.expr(node.left)
				g.write('), _ARR_LEN(')
				g.expr(node.left)
				g.write('), sizeof(')
				g.expr(node.left)
				g.write('[0]), ')
				g.expr(node.left)
				g.write(')')
			} else {
				g.expr(node.left)
			}
			g.write(', ')
			if it.has_low {
				g.expr(it.low)
			} else {
				g.write('0')
			}
			g.write(', ')
			if it.has_high {
				g.expr(it.high)
			} else {
				g.expr(node.left)
				g.write('.len')
			}
			g.write(')')
		}
		else {
			sym := g.table.get_type_symbol(node.left_type)
			left_is_ptr := node.left_type.is_ptr()
			if node.left_type.has_flag(.variadic) {
				g.expr(node.left)
				g.write('.args')
				g.write('[')
				g.expr(node.index)
				g.write(']')
			} else if sym.kind == .array {
				info := sym.info as table.Array
				elem_type_str := g.typ(info.elem_type)
				// `vals[i].field = x` is an exception and requires `array_get`:
				// `(*(Val*)array_get(vals, i)).field = x;`
				is_selector := node.left is ast.SelectorExpr
				if g.is_assign_lhs && !is_selector && node.is_setter {
					g.is_array_set = true
					g.write('array_set(')
					if !left_is_ptr || node.left_type.has_flag(.shared_f) {
						g.write('&')
					}
					g.expr(node.left)
					if node.left_type.has_flag(.shared_f) {
						if left_is_ptr {
							g.write('->val')
						} else {
							g.write('.val')
						}
					}
					g.write(', ')
					g.expr(node.index)
					mut need_wrapper := true
					/*
					match node.right {
						ast.EnumVal, ast.Ident {
							// `&x` is enough for variables and enums
							// `&(Foo[]){ ... }` is only needed for function calls and literals
							need_wrapper = false
						}
						else {}
					}
					*/
					if need_wrapper {
						g.write(', &($elem_type_str[]) { ')
					} else {
						g.write(', &')
					}
					// `x[0] *= y`
					if g.assign_op != .assign &&
						g.assign_op in token.assign_tokens &&
						info.elem_type != table.string_type {
						// TODO move this
						g.write('*($elem_type_str*)array_get(')
						if left_is_ptr && !node.left_type.has_flag(.shared_f) {
							g.write('*')
						}
						g.expr(node.left)
						if node.left_type.has_flag(.shared_f) {
							if left_is_ptr {
								g.write('->val')
							} else {
								g.write('.val')
							}
						}
						g.write(', ')
						g.expr(node.index)
						g.write(') ')
						op := match g.assign_op {
							.mult_assign { '*' }
							.plus_assign { '+' }
							.minus_assign { '-' }
							.div_assign { '/' }
							.xor_assign { '^' }
							.mod_assign { '%' }
							.or_assign { '|' }
							.and_assign { '&' }
							.left_shift_assign { '<<' }
							.right_shift_assign { '>>' }
							else { '' }
						}
						g.write(op)
					}
				} else {
					g.write('(*($elem_type_str*)array_get(')
					if left_is_ptr && !node.left_type.has_flag(.shared_f) {
						g.write('*')
					}
					g.expr(node.left)
					if node.left_type.has_flag(.shared_f) {
						if left_is_ptr {
							g.write('->val')
						} else {
							g.write('.val')
						}
					}
					g.write(', ')
					g.expr(node.index)
					g.write('))')
				}
			} else if sym.kind == .map {
				info := sym.info as table.Map
				elem_type_str := g.typ(info.value_type)
				if g.is_assign_lhs && !g.is_array_set {
					g.is_array_set = true
					g.write('map_set(')
					if !left_is_ptr {
						g.write('&')
					}
					g.expr(node.left)
					g.write(', ')
					g.expr(node.index)
					g.write(', &($elem_type_str[]) { ')
				} else if g.inside_map_postfix || g.inside_map_infix {
					zero := g.type_default(info.value_type)
					g.write('(*($elem_type_str*)map_get_and_set(')
					if !left_is_ptr {
						g.write('&')
					}
					g.expr(node.left)
					g.write(', ')
					g.expr(node.index)
					g.write(', &($elem_type_str[]){ $zero }))')
				} else {
					zero := g.type_default(info.value_type)
					g.write('(*($elem_type_str*)map_get(')
					if node.left_type.is_ptr() {
						g.write('*')
					}
					g.expr(node.left)
					g.write(', ')
					g.expr(node.index)
					g.write(', &($elem_type_str[]){ $zero }))')
				}
			} else if sym.kind == .string && !node.left_type.is_ptr() {
				g.write('string_at(')
				g.expr(node.left)
				g.write(', ')
				g.expr(node.index)
				g.write(')')
			} else {
				g.expr(node.left)
				g.write('[')
				g.expr(node.index)
				g.write(']')
			}
		}
	}
}

[inline]
fn (g Gen) expr_is_multi_return_call(expr ast.Expr) bool {
	match expr {
		ast.CallExpr { return g.table.get_type_symbol(expr.return_type).kind == .multi_return }
		else { return false }
	}
}

fn (mut g Gen) return_statement(node ast.Return) {
	if node.exprs.len > 0 {
		// skip `retun $vweb.html()`
		if node.exprs[0] is ast.ComptimeCall {
			g.expr(node.exprs[0])
			g.writeln(';')
			return
		}
	}
	g.inside_return = true
	defer {
		g.inside_return = false
	}
	// got to do a correct check for multireturn
	sym := g.table.get_type_symbol(g.fn_decl.return_type)
	fn_return_is_multi := sym.kind == .multi_return
	fn_return_is_optional := g.fn_decl.return_type.has_flag(.optional)
	if node.exprs.len == 0 {
		if fn_return_is_optional {
			tmp := g.new_tmp_var()
			styp := g.typ(g.fn_decl.return_type)
			g.writeln('$styp $tmp = {.ok = true};')
			g.writeln('return $tmp;')
		} else {
			g.writeln('return;')
		}
		return
	}
	// handle promoting none/error/function returning 'Option'
	if fn_return_is_optional {
		optional_none := node.exprs[0] is ast.None
		mut is_regular_option := g.typ(node.types[0]) == 'Option'
		if optional_none || is_regular_option {
			tmp := g.new_tmp_var()
			g.write('Option $tmp = ')
			g.expr_with_cast(node.exprs[0], node.types[0], g.fn_decl.return_type)
			g.writeln(';')
			styp := g.typ(g.fn_decl.return_type)
			g.writeln('return *($styp*)&$tmp;')
			return
		}
	}
	// regular cases
	if fn_return_is_multi { // not_optional_none { //&& !fn_return_is_optional {
		// typ_sym := g.table.get_type_symbol(g.fn_decl.return_type)
		// mr_info := typ_sym.info as table.MultiReturn
		mut styp := ''
		mut opt_tmp := ''
		mut opt_type := ''
		if fn_return_is_optional {
			opt_type = g.typ(g.fn_decl.return_type)
			// Create a tmp for this option
			opt_tmp = g.new_tmp_var()
			g.writeln('$opt_type $opt_tmp;')
			styp = g.base_type(g.fn_decl.return_type)
			g.write('opt_ok2(&($styp/*X*/[]) { ')
		} else {
			g.write('return ')
			styp = g.typ(g.fn_decl.return_type)
		}
		// Edge case handling for 2 multi returns of the same type
		if node.exprs.len == 1 && g.expr_is_multi_return_call(node.exprs[0]) {
			g.go_before_stmt(0)
			g.write('return ')
			g.expr(node.exprs[0])
			g.writeln(';')
			return
		}
		// Use this to keep the tmp assignments in order
		mut multi_unpack := ''
		g.write('($styp){')
		mut arg_idx := 0
		for i, expr in node.exprs {
			// Check if we are dealing with a multi return and handle it seperately
			if g.expr_is_multi_return_call(expr) {
				c := expr as ast.CallExpr
				expr_sym := g.table.get_type_symbol(c.return_type)
				// Create a tmp for this call
				tmp := g.new_tmp_var()
				s := g.go_before_stmt(0)
				expr_styp := g.typ(c.return_type)
				g.write('$expr_styp $tmp=')
				g.expr(expr)
				g.writeln(';')
				multi_unpack += g.go_before_stmt(0)
				g.write(s)
				expr_types := expr_sym.mr_info().types
				for j, _ in expr_types {
					g.write('.arg$arg_idx=${tmp}.arg$j')
					if j < expr_types.len || i < node.exprs.len - 1 {
						g.write(',')
					}
					arg_idx++
				}
				continue
			}
			g.write('.arg$arg_idx=')
			g.expr(expr)
			arg_idx++
			if i < node.exprs.len - 1 {
				g.write(', ')
			}
		}
		g.write('}')
		if fn_return_is_optional {
			g.writeln(' }, (OptionBase*)(&$opt_tmp), sizeof($styp));')
			g.write('return $opt_tmp')
		}
		// Make sure to add our unpacks
		if multi_unpack.len > 0 {
			g.insert_before_stmt(multi_unpack)
		}
	} else if node.exprs.len >= 1 {
		// normal return
		return_sym := g.table.get_type_symbol(node.types[0])
		// `return opt_ok(expr)` for functions that expect an optional
		if fn_return_is_optional && !node.types[0].has_flag(.optional) &&
			return_sym.name != 'Option' {
			styp := g.base_type(g.fn_decl.return_type)
			opt_type := g.typ(g.fn_decl.return_type)
			// Create a tmp for this option
			opt_tmp := g.new_tmp_var()
			g.writeln('$opt_type $opt_tmp;')
			g.write('opt_ok2(&($styp[]) { ')
			if !g.fn_decl.return_type.is_ptr() && node.types[0].is_ptr() {
				// Automatic Dereference for optional
				g.write('*')
			}
			for i, expr in node.exprs {
				g.expr(expr)
				if i < node.exprs.len - 1 {
					g.write(', ')
				}
			}
			g.writeln(' }, (OptionBase*)(&$opt_tmp), sizeof($styp));')
			g.writeln('return $opt_tmp;')
			return
		}
		free := g.pref.autofree && node.exprs[0] is ast.CallExpr
		mut tmp := ''
		if free {
			// `return foo(a, b, c)`
			// `tmp := foo(a, b, c); free(a); free(b); free(c); return tmp;`
			// Save return value in a temp var so that it all args (a,b,c) can be freed
			tmp = g.new_tmp_var()
			g.write(g.typ(g.fn_decl.return_type))
			g.write(' ')
			g.write(tmp)
			g.write(' = ')
			// g.write('return $tmp;')
		} else {
			g.write('return ')
		}
		cast_interface := sym.kind == .interface_ && node.types[0] != g.fn_decl.return_type
		if cast_interface {
			g.interface_call(node.types[0], g.fn_decl.return_type)
		}
		g.expr_with_cast(node.exprs[0], node.types[0], g.fn_decl.return_type)
		if cast_interface {
			g.write(')')
		}
		if free {
			g.writeln('; // free tmp exprs')
			g.autofree_scope_vars(node.pos.pos + 1)
			g.write('return $tmp')
		}
	} else {
		g.write('return')
	}
	g.writeln(';')
}

fn (mut g Gen) const_decl(node ast.ConstDecl) {
	g.inside_const = true
	defer {
		g.inside_const = false
	}
	for field in node.fields {
		name := c_name(field.name)
		// TODO hack. Cut the generated value and paste it into definitions.
		pos := g.out.len
		g.expr(field.expr)
		val := g.out.after(pos)
		g.out.go_back(val.len)
		/*
		if field.typ == table.byte_type {
			g.const_decl_simple_define(name, val)
			return
		}
		*/
		/*
		if table.is_number(field.typ) {
			g.const_decl_simple_define(name, val)
		} else if field.typ == table.string_type {
			g.definitions.writeln('string _const_$name; // a string literal, inited later')
			if g.pref.build_mode != .build_module {
				g.stringliterals.writeln('\t_const_$name = $val;')
			}
		} else {
		*/
		match field.expr {
			ast.CharLiteral {
				g.const_decl_simple_define(name, val)
			}
			ast.FloatLiteral {
				g.const_decl_simple_define(name, val)
			}
			ast.IntegerLiteral {
				g.const_decl_simple_define(name, val)
			}
			ast.ArrayInit {
				if it.is_fixed {
					styp := g.typ(it.typ)
					g.definitions.writeln('$styp _const_$name = $val; // fixed array const')
				} else {
					g.const_decl_init_later(field.mod, name, val, field.typ)
				}
			}
			ast.StringLiteral {
				g.definitions.writeln('static string _const_$name; // a string literal, inited later')
				if g.pref.build_mode != .build_module {
					g.stringliterals.writeln('\t_const_$name = $val;')
				}
			}
			else {
				g.const_decl_init_later(field.mod, name, val, field.typ)
			}
		}
	}
}

fn (mut g Gen) const_decl_simple_define(name, val string) {
	// Simple expressions should use a #define
	// so that we don't pollute the binary with unnecessary global vars
	// Do not do this when building a module, otherwise the consts
	// will not be accessible.
	g.definitions.write('#define _const_$name ')
	g.definitions.writeln(val)
}

fn (mut g Gen) const_decl_init_later(mod, name, val string, typ table.Type) {
	// Initialize more complex consts in `void _vinit(){}`
	// (C doesn't allow init expressions that can't be resolved at compile time).
	styp := g.typ(typ)
	//
	cname := '_const_$name'
	g.definitions.writeln('static $styp $cname; // inited later')
	g.inits[mod].writeln('\t$cname = $val;')
	if g.pref.autofree {
		if styp.starts_with('array_') {
			g.cleanups[mod].writeln('\tarray_free(&$cname);')
		}
		if styp == 'string' {
			g.cleanups[mod].writeln('\tstring_free(&$cname);')
		}
	}
}

fn (mut g Gen) go_back_out(n int) {
	g.out.go_back(n)
}

const (
	skip_struct_init = ['strconv__ftoa__Uf32', 'strconv__ftoa__Uf64', 'strconv__Float64u', 'struct stat',
		'struct addrinfo',
	]
)

fn (mut g Gen) struct_init(struct_init ast.StructInit) {
	styp := g.typ(struct_init.typ)
	mut shared_styp := '' // only needed for shared &St{...
	if styp in skip_struct_init {
		g.go_back_out(3)
		return
	}
	sym := g.table.get_type_symbol(struct_init.typ)
	is_amp := g.is_amp
	is_multiline := struct_init.fields.len > 5
	g.is_amp = false // reset the flag immediately so that other struct inits in this expr are handled correctly
	if is_amp {
		g.out.go_back(1) // delete the `&` already generated in `prefix_expr()
		if g.is_shared {
			mut shared_typ := struct_init.typ.set_flag(.shared_f)
			shared_styp = g.typ(shared_typ)
			g.writeln('($shared_styp*)memdup(&($shared_styp){.val = ($styp){')
		} else {
			g.write('($styp*)memdup(&($styp){')
		}
	} else {
		if g.is_shared {
			g.writeln('{.val = {')
		} else if is_multiline {
			g.writeln('($styp){')
		} else {
			g.write('($styp){')
		}
	}
	// mut fields := []string{}
	mut inited_fields := map[string]int{} // TODO this is done in checker, move to ast node
	/*
	if struct_init.fields.len == 0 && struct_init.exprs.len > 0 {
		// Get fields for {a,b} short syntax. Fields array wasn't set in the parser.
		for f in info.fields {
			fields << f.name
		}
	} else {
		fields = struct_init.fields
	}
	*/
	if is_multiline {
		g.indent++
	}
	// User set fields
	mut initialized := false
	for i, field in struct_init.fields {
		inited_fields[field.name] = i
		if sym.kind != .struct_ {
			field_name := c_name(field.name)
			g.write('.$field_name = ')
			field_type_sym := g.table.get_type_symbol(field.typ)
			mut cloned := false
			if g.autofree && field_type_sym.kind in [.array, .string] {
				g.write('/*clone1*/')
				if g.gen_clone_assignment(field.expr, field_type_sym, false) {
					cloned = true
				}
			}
			if !cloned {
				if field.expected_type.is_ptr() && !field.typ.is_ptr() && !field.typ.is_number() {
					g.write('/* autoref */&')
				}
				g.expr_with_cast(field.expr, field.typ, field.expected_type)
			}
			if i != struct_init.fields.len - 1 {
				if is_multiline {
					g.writeln(',')
				} else {
					g.write(', ')
				}
			}
			initialized = true
		}
	}
	// The rest of the fields are zeroed.
	// `inited_fields` is a list of fields that have been init'ed, they are skipped
	// mut nr_fields := 0
	if sym.kind == .struct_ {
		info := sym.info as table.Struct
		if info.is_union && struct_init.fields.len > 1 {
			verror('union must not have more than 1 initializer')
		}
		// g.zero_struct_fields(info, inited_fields)
		// nr_fields = info.fields.len
		for field in info.fields {
			if field.name in inited_fields {
				sfield := struct_init.fields[inited_fields[field.name]]
				field_name := c_name(sfield.name)
				g.write('.$field_name = ')
				field_type_sym := g.table.get_type_symbol(sfield.typ)
				mut cloned := false
				if g.autofree && field_type_sym.kind in [.array, .string] {
					g.write('/*clone1*/')
					if g.gen_clone_assignment(sfield.expr, field_type_sym, false) {
						cloned = true
					}
				}
				if !cloned {
					if sfield.expected_type.is_ptr() && !sfield.typ.is_ptr() && !sfield.typ.is_number() {
						g.write('/* autoref */&')
					}
					g.expr_with_cast(sfield.expr, sfield.typ, sfield.expected_type)
				}
				if is_multiline {
					g.writeln(',')
				} else {
					g.write(',')
				}
				initialized = true
				continue
			}
			if info.is_union {
				// unions thould have exactly one explicit initializer
				continue
			}
			if field.typ.has_flag(.optional) {
				// TODO handle/require optionals in inits
				continue
			}
			g.zero_struct_field(field)
			if is_multiline {
				g.writeln(',')
			} else {
				g.write(',')
			}
			initialized = true
		}
	}
	if is_multiline {
		g.indent--
	}
	// if struct_init.fields.len == 0 && info.fields.len == 0 {
	if !initialized {
		g.write('\n#ifndef __cplusplus\n0\n#endif\n')
	}
	g.write('}')
	if g.is_shared {
		g.write(', .mtx = sync__new_rwmutex()}')
		if is_amp {
			g.write(', sizeof($shared_styp))')
		}
	} else if is_amp {
		g.write(', sizeof($styp))')
	}
}

fn (mut g Gen) zero_struct_field(field table.Field) {
	field_name := c_name(field.name)
	g.write('.$field_name = ')
	if field.has_default_expr {
		g.expr(ast.fe2ex(field.default_expr))
	} else {
		g.write(g.type_default(field.typ))
	}
}

// fn (mut g Gen) zero_struct_fields(info table.Struct, inited_fields map[string]int) {
// }
// { user | name: 'new name' }
fn (mut g Gen) assoc(node ast.Assoc) {
	g.writeln('// assoc')
	if node.typ == 0 {
		return
	}
	styp := g.typ(node.typ)
	g.writeln('($styp){')
	mut inited_fields := map[string]int{}
	for i, field in node.fields {
		inited_fields[field] = i
	}
	// Merge inited_fields in the rest of the fields.
	sym := g.table.get_type_symbol(node.typ)
	info := sym.info as table.Struct
	for field in info.fields {
		field_name := c_name(field.name)
		if field.name in inited_fields {
			g.write('\t.$field_name = ')
			g.expr(node.exprs[inited_fields[field.name]])
			g.writeln(', ')
		} else {
			g.writeln('\t.$field_name = ${node.var_name}.$field_name,')
		}
	}
	g.write('}')
	if g.is_amp {
		g.write(', sizeof($styp))')
	}
}

fn (mut g Gen) gen_array_equality_fn(left table.Type) string {
	left_sym := g.table.get_type_symbol(left)
	typ_name := g.typ(left)
	ptr_typ := typ_name[typ_name.index_after('_', 0) + 1..].trim('*')
	elem_sym := g.table.get_type_symbol(left_sym.array_info().elem_type)
	elem_typ := g.typ(left_sym.array_info().elem_type)
	ptr_elem_typ := elem_typ[elem_typ.index_after('_', 0) + 1..]
	if elem_sym.kind == .array {
		// Recursively generate array element comparison function code if array element is array type
		g.gen_array_equality_fn(left_sym.array_info().elem_type)
	}
	if ptr_typ in g.array_fn_definitions {
		return ptr_typ
	}
	g.array_fn_definitions << ptr_typ
	g.definitions.writeln('bool ${ptr_typ}_arr_eq(array_$ptr_typ a, array_$ptr_typ b) {')
	g.definitions.writeln('\tif (a.len != b.len) {')
	g.definitions.writeln('\t\treturn false;')
	g.definitions.writeln('\t}')
	g.definitions.writeln('\tfor (int i = 0; i < a.len; ++i) {')
	if elem_sym.kind == .string {
		g.definitions.writeln('\t\tif (string_ne(*(($ptr_typ*)((byte*)a.data+(i*a.element_size))), *(($ptr_typ*)((byte*)b.data+(i*b.element_size))))) {')
	} else if elem_sym.kind == .struct_ {
		g.definitions.writeln('\t\tif (memcmp((byte*)a.data+(i*a.element_size), (byte*)b.data+(i*b.element_size), a.element_size)) {')
	} else if elem_sym.kind == .array {
		g.definitions.writeln('\t\tif (!${ptr_elem_typ}_arr_eq((($elem_typ*)a.data)[i], (($elem_typ*)b.data)[i])) {')
	} else {
		g.definitions.writeln('\t\tif (*(($ptr_typ*)((byte*)a.data+(i*a.element_size))) != *(($ptr_typ*)((byte*)b.data+(i*b.element_size)))) {')
	}
	g.definitions.writeln('\t\t\treturn false;')
	g.definitions.writeln('\t\t}')
	g.definitions.writeln('\t}')
	g.definitions.writeln('\treturn true;')
	g.definitions.writeln('}')
	return ptr_typ
}

fn (mut g Gen) gen_map_equality_fn(left table.Type) string {
	left_sym := g.table.get_type_symbol(left)
	typ_name := g.typ(left)
	ptr_typ := typ_name[typ_name.index_after('_', 0) + 1..].trim('*')
	value_sym := g.table.get_type_symbol(left_sym.map_info().value_type)
	value_typ := g.typ(left_sym.map_info().value_type)
	if value_sym.kind == .map {
		// Recursively generate map element comparison function code if array element is map type
		g.gen_map_equality_fn(left_sym.map_info().value_type)
	}
	if ptr_typ in g.map_fn_definitions {
		return ptr_typ
	}
	g.map_fn_definitions << ptr_typ
	g.definitions.writeln('bool ${ptr_typ}_map_eq(map_$ptr_typ a, map_$ptr_typ b) {')
	g.definitions.writeln('\tif (a.len != b.len) {')
	g.definitions.writeln('\t\treturn false;')
	g.definitions.writeln('\t}')
	g.definitions.writeln('\tarray_string _keys = map_keys(&a);')
	g.definitions.writeln('\tfor (int i = 0; i < _keys.len; ++i) {')
	g.definitions.writeln('\t\tstring k = string_clone( ((string*)_keys.data)[i]);')
	g.definitions.writeln('\t\t$value_typ v = (*($value_typ*)map_get(a, k, &($value_typ[]){ 0 }));')
	if value_sym.kind == .string {
		g.definitions.writeln('\t\tif (!map_exists(b, k) || string_ne((*($value_typ*)map_get(b, k, &($value_typ[]){tos_lit("")})), v)) {')
	} else {
		g.definitions.writeln('\t\tif (!map_exists(b, k) || (*($value_typ*)map_get(b, k, &($value_typ[]){ 0 })) != v) {')
	}
	g.definitions.writeln('\t\t\treturn false;')
	g.definitions.writeln('\t\t}')
	g.definitions.writeln('\t}')
	g.definitions.writeln('\treturn true;')
	g.definitions.writeln('}')
	return ptr_typ
}

fn verror(s string) {
	util.verror('cgen error', s)
}

fn (mut g Gen) write_init_function() {
	if g.pref.is_liveshared {
		return
	}
	fn_vinit_start_pos := g.out.len
	needs_constructor := g.pref.is_shared && g.pref.os != .windows
	if needs_constructor {
		g.writeln('__attribute__ ((constructor))')
		g.writeln('void _vinit() {')
		g.writeln('static bool once = false; if (once) {return;} once = true;')
	} else {
		g.writeln('void _vinit() {')
	}
	if g.pref.autofree {
		// Pre-allocate the string buffer
		// s_str_buf_size := os.getenv('V_STRBUF_MB')
		// mb_size := if s_str_buf_size == '' { 1 } else { s_str_buf_size.int() }
		// g.writeln('g_str_buf = malloc( ${mb_size} * 1024 * 1000 );')
	}
	if g.pref.prealloc {
		g.writeln('g_m2_buf = malloc(50 * 1000 * 1000);')
		g.writeln('g_m2_ptr = g_m2_buf;')
	}
	g.writeln('\tbuiltin_init();')
	g.writeln('\tvinit_string_literals();')
	//
	for mod_name in g.table.modules {
		g.writeln('\t// Initializations for module $mod_name :')
		g.write(g.inits[mod_name].str())
		init_fn_name := '${mod_name}.init'
		if initfn := g.table.find_fn(init_fn_name) {
			if initfn.return_type == table.void_type && initfn.args.len == 0 {
				mod_c_name := util.no_dots(mod_name)
				init_fn_c_name := '${mod_c_name}__init'
				g.writeln('\t${init_fn_c_name}();')
			}
		}
	}
	//
	g.writeln('}')
	if g.pref.printfn_list.len > 0 && '_vinit' in g.pref.printfn_list {
		println(g.out.after(fn_vinit_start_pos))
	}
	if g.autofree {
		fn_vcleanup_start_pos := g.out.len
		g.writeln('void _vcleanup() {')
		// g.writeln('puts("cleaning up...");')
		reversed_table_modules := g.table.modules.reverse()
		for mod_name in reversed_table_modules {
			g.writeln('\t// Cleanups for module $mod_name :')
			g.writeln(g.cleanups[mod_name].str())
		}
		// g.writeln('\tfree(g_str_buf);')
		g.writeln('}')
		if g.pref.printfn_list.len > 0 && '_vcleanup' in g.pref.printfn_list {
			println(g.out.after(fn_vcleanup_start_pos))
		}
	}
}

const (
	builtins = ['string', 'array', 'KeyValue', 'DenseArray', 'map', 'Option']
)

fn (mut g Gen) write_builtin_types() {
	mut builtin_types := []table.TypeSymbol{} // builtin types
	// builtin types need to be on top
	// everything except builtin will get sorted
	for builtin_name in builtins {
		builtin_types << g.table.types[g.table.type_idxs[builtin_name]]
	}
	g.write_types(builtin_types)
}

// C struct definitions, ordered
// Sort the types, make sure types that are referenced by other types
// are added before them.
fn (mut g Gen) write_sorted_types() {
	mut types := []table.TypeSymbol{} // structs that need to be sorted
	for typ in g.table.types {
		if typ.name !in builtins {
			types << typ
		}
	}
	// sort structs
	types_sorted := g.sort_structs(types)
	// Generate C code
	g.type_definitions.writeln('// builtin types:')
	g.type_definitions.writeln('//------------------ #endbuiltin')
	g.write_types(types_sorted)
}

fn (mut g Gen) write_types(types []table.TypeSymbol) {
	for typ in types {
		if typ.name.starts_with('C.') {
			continue
		}
		// sym := g.table.get_type_symbol(typ)
		mut name := util.no_dots(typ.name)
		match typ.info as info {
			table.Struct {
				if info.generic_types.len > 0 {
					continue
				}
				// TODO: yuck
				if name.contains('<') {
					name = name.replace('<', '_T_').replace('>', '').replace(',', '_')
					g.typedefs.writeln('typedef struct $name $name;')
				}
				// TODO avoid buffer manip
				start_pos := g.type_definitions.len
				if info.is_union {
					g.type_definitions.writeln('union $name {')
				} else {
					g.type_definitions.writeln('struct $name {')
				}
				if info.fields.len > 0 {
					for field in info.fields {
						// Some of these structs may want to contain
						// optionals that may not be defined at this point
						// if this is the case then we are going to
						// buffer manip out in front of the struct
						// write the optional in and then continue
						if field.typ.has_flag(.optional) {
							// Dont use g.typ() here becuase it will register
							// optional and we dont want that
							last_text := g.type_definitions.after(start_pos).clone()
							g.type_definitions.go_back_to(start_pos)
							styp, base := g.optional_type_name(field.typ)
							g.optionals << styp
							g.typedefs2.writeln('typedef struct $styp $styp;')
							g.type_definitions.writeln('${g.optional_type_text(styp,base)};')
							g.type_definitions.write(last_text)
						}
						type_name := g.typ(field.typ)
						field_name := c_name(field.name)
						g.type_definitions.writeln('\t$type_name $field_name;')
					}
				} else {
					g.type_definitions.writeln('EMPTY_STRUCT_DECLARATION;')
				}
				// g.type_definitions.writeln('} $name;\n')
				//
				g.type_definitions.writeln('};\n')
			}
			table.Alias {
				// table.Alias, table.SumType { TODO
			}
			table.SumType {
				g.type_definitions.writeln('')
				g.type_definitions.writeln('// Sum type $name = ')
				for sv in it.variants {
					g.type_definitions.writeln('//          | ${sv:4d} = ${g.typ(sv):-20s}')
				}
				g.type_definitions.writeln('typedef struct {')
				g.type_definitions.writeln('    void* obj;')
				g.type_definitions.writeln('    int typ;')
				g.type_definitions.writeln('} $name;')
				g.type_definitions.writeln('')
			}
			table.ArrayFixed {
				// .array_fixed {
				styp := util.no_dots(typ.name)
				// array_fixed_char_300 => char x[300]
				mut fixed := styp[12..]
				len := styp.after('_')
				fixed = fixed[..fixed.len - len.len - 1]
				if fixed.starts_with('C__') {
					fixed = fixed[3..]
				}
				g.type_definitions.writeln('typedef $fixed $styp [$len];')
				// }
			}
			else {}
		}
	}
}

// sort structs by dependant fields
fn (g Gen) sort_structs(typesa []table.TypeSymbol) []table.TypeSymbol {
	mut dep_graph := depgraph.new_dep_graph()
	// types name list
	mut type_names := []string{}
	for typ in typesa {
		type_names << typ.name
	}
	// loop over types
	for t in typesa {
		if t.kind == .interface_ {
			dep_graph.add(t.name, [])
			continue
		}
		// create list of deps
		mut field_deps := []string{}
		match t.info {
			table.ArrayFixed {
				dep := g.table.get_type_symbol(it.elem_type).name
				if dep in type_names {
					field_deps << dep
				}
			}
			table.Struct {
				info := t.info as table.Struct
				// if info.is_interface {
				// continue
				// }
				for field in info.fields {
					dep := g.table.get_type_symbol(field.typ).name
					// skip if not in types list or already in deps
					if dep !in type_names || dep in field_deps || field.typ.is_ptr() {
						continue
					}
					field_deps << dep
				}
			}
			// table.Interface {}
			else {}
		}
		// add type and dependant types to graph
		dep_graph.add(t.name, field_deps)
	}
	// sort graph
	dep_graph_sorted := dep_graph.resolve()
	if !dep_graph_sorted.acyclic {
		verror('cgen.sort_structs(): the following structs form a dependency cycle:\n' + dep_graph_sorted.display_cycles() +
			'\nyou can solve this by making one or both of the dependant struct fields references, eg: field &MyStruct' +
			'\nif you feel this is an error, please create a new issue here: https://github.com/vlang/v/issues and tag @joe-conigliaro')
	}
	// sort types
	mut types_sorted := []table.TypeSymbol{}
	for node in dep_graph_sorted.nodes {
		types_sorted << g.table.types[g.table.type_idxs[node.name]]
	}
	return types_sorted
}

fn (mut g Gen) gen_expr_to_string(expr ast.Expr, etype table.Type) ?bool {
	sym := g.table.get_type_symbol(etype)
	sym_has_str_method, str_method_expects_ptr, _ := sym.str_method_info()
	if etype.has_flag(.variadic) {
		str_fn_name := g.gen_str_for_type(etype)
		g.write('${str_fn_name}(')
		g.expr(expr)
		g.write(')')
	} else if sym.kind == .alias && (sym.info as table.Alias).parent_type == table.string_type {
		// handle string aliases
		g.expr(expr)
		return true
	} else if sym.kind == .enum_ {
		is_var := match expr {
			ast.SelectorExpr { true }
			ast.Ident { true }
			else { false }
		}
		if is_var {
			str_fn_name := g.gen_str_for_type(etype)
			g.write('${str_fn_name}(')
			g.enum_expr(expr)
			g.write(')')
		} else {
			g.write('tos_lit("')
			g.enum_expr(expr)
			g.write('")')
		}
	} else if sym_has_str_method || sym.kind in [.array, .array_fixed, .map, .struct_, .multi_return] {
		is_p := etype.is_ptr()
		val_type := if is_p { etype.deref() } else { etype }
		str_fn_name := g.gen_str_for_type(val_type)
		if is_p && str_method_expects_ptr {
			g.write('string_add(_SLIT("&"), ${str_fn_name}(  (')
		}
		if is_p && !str_method_expects_ptr {
			g.write('string_add(_SLIT("&"), ${str_fn_name}( *(')
		}
		if !is_p && !str_method_expects_ptr {
			g.write('${str_fn_name}(  ')
		}
		if !is_p && str_method_expects_ptr {
			g.write('${str_fn_name}( &')
		}
		g.expr(expr)
		if sym.kind == .struct_ && !sym_has_str_method {
			if is_p {
				g.write(')))')
			} else {
				g.write(')')
			}
		} else {
			if is_p {
				g.write(')))')
			} else {
				g.write(')')
			}
		}
	} else if g.typ(etype).starts_with('Option') {
		str_fn_name := 'OptionBase_str'
		g.write('${str_fn_name}(*(OptionBase*)&')
		g.expr(expr)
		g.write(')')
	} else {
		return error('cannot convert to string')
	}
	return true
}

// `nums.map(it % 2 == 0)`
fn (mut g Gen) gen_array_map(node ast.CallExpr) {
	tmp := g.new_tmp_var()
	s := g.go_before_stmt(0)
	// println('filter s="$s"')
	ret_typ := g.typ(node.return_type)
	// inp_typ := g.typ(node.receiver_type)
	ret_sym := g.table.get_type_symbol(node.return_type)
	inp_sym := g.table.get_type_symbol(node.receiver_type)
	ret_info := ret_sym.info as table.Array
	ret_elem_type := g.typ(ret_info.elem_type)
	inp_info := inp_sym.info as table.Array
	inp_elem_type := g.typ(inp_info.elem_type)
	if inp_sym.kind != .array {
		verror('map() requires an array')
	}
	g.writeln('')
	g.write('int ${tmp}_len = ')
	g.expr(node.left)
	g.writeln('.len;')
	g.writeln('$ret_typ $tmp = __new_array(0, ${tmp}_len, sizeof($ret_elem_type));')
	i := g.new_tmp_var()
	g.writeln('for (int $i = 0; $i < ${tmp}_len; ++$i) {')
	g.write('\t$inp_elem_type it = (($inp_elem_type*) ')
	g.expr(node.left)
	g.writeln('.data)[$i];')
	g.write('\t$ret_elem_type ti = ')
	match node.args[0].expr {
		ast.AnonFn {
			g.gen_anon_fn_decl(it)
			g.write('${it.decl.name}(it)')
		}
		ast.Ident {
			if it.kind == .function {
				g.write('${c_name(it.name)}(it)')
			} else if it.kind == .variable {
				var_info := it.var_info()
				sym := g.table.get_type_symbol(var_info.typ)
				if sym.kind == .function {
					g.write('${c_name(it.name)}(it)')
				} else {
					g.expr(node.args[0].expr)
				}
			} else {
				g.expr(node.args[0].expr)
			}
		}
		else {
			g.expr(node.args[0].expr)
		}
	}
	g.writeln(';')
	g.writeln('\tarray_push(&$tmp, &ti);')
	g.writeln('}')
	g.write(s)
	g.write(tmp)
}

// `nums.filter(it % 2 == 0)`
fn (mut g Gen) gen_array_filter(node ast.CallExpr) {
	tmp := g.new_tmp_var()
	s := g.go_before_stmt(0)
	// println('filter s="$s"')
	sym := g.table.get_type_symbol(node.return_type)
	if sym.kind != .array {
		verror('filter() requires an array')
	}
	info := sym.info as table.Array
	styp := g.typ(node.return_type)
	elem_type_str := g.typ(info.elem_type)
	g.write('\nint ${tmp}_len = ')
	g.expr(node.left)
	g.writeln('.len;')
	g.writeln('$styp $tmp = __new_array(0, ${tmp}_len, sizeof($elem_type_str));')
	g.writeln('for (int i = 0; i < ${tmp}_len; ++i) {')
	g.write('  $elem_type_str it = (($elem_type_str*) ')
	g.expr(node.left)
	g.writeln('.data)[i];')
	g.write('if (')
	match node.args[0].expr {
		ast.AnonFn {
			g.gen_anon_fn_decl(it)
			g.write('${it.decl.name}(it)')
		}
		ast.Ident {
			if it.kind == .function {
				g.write('${c_name(it.name)}(it)')
			} else if it.kind == .variable {
				var_info := it.var_info()
				sym_t := g.table.get_type_symbol(var_info.typ)
				if sym_t.kind == .function {
					g.write('${c_name(it.name)}(it)')
				} else {
					g.expr(node.args[0].expr)
				}
			} else {
				g.expr(node.args[0].expr)
			}
		}
		else {
			g.expr(node.args[0].expr)
		}
	}
	g.writeln(') array_push(&$tmp, &it); \n }')
	g.write(s)
	g.write(' ')
	g.write(tmp)
}

// `nums.insert(0, 2)` `nums.insert(0, [2,3,4])`
fn (mut g Gen) gen_array_insert(node ast.CallExpr) {
	left_sym := g.table.get_type_symbol(node.left_type)
	left_info := left_sym.info as table.Array
	elem_type_str := g.typ(left_info.elem_type)
	arg2_sym := g.table.get_type_symbol(node.args[1].typ)
	is_arg2_array := arg2_sym.kind == .array
	if is_arg2_array {
		g.write('array_insert_many(&')
	} else {
		g.write('array_insert(&')
	}
	g.expr(node.left)
	g.write(', ')
	g.expr(node.args[0].expr)
	if is_arg2_array {
		g.write(', ')
		g.expr(node.args[1].expr)
		g.write('.data, ')
		g.expr(node.args[1].expr)
		g.write('.len)')
	} else {
		g.write(', &($elem_type_str[]){')
		g.expr(node.args[1].expr)
		g.write('})')
	}
}

// `nums.prepend(2)` `nums.prepend([2,3,4])`
fn (mut g Gen) gen_array_prepend(node ast.CallExpr) {
	left_sym := g.table.get_type_symbol(node.left_type)
	left_info := left_sym.info as table.Array
	elem_type_str := g.typ(left_info.elem_type)
	arg_sym := g.table.get_type_symbol(node.args[0].typ)
	is_arg_array := arg_sym.kind == .array
	if is_arg_array {
		g.write('array_prepend_many(&')
	} else {
		g.write('array_prepend(&')
	}
	g.expr(node.left)
	if is_arg_array {
		g.write(', ')
		g.expr(node.args[0].expr)
		g.write('.data, ')
		g.expr(node.args[0].expr)
		g.write('.len)')
	} else {
		g.write(', &($elem_type_str[]){')
		g.expr(node.args[0].expr)
		g.write('})')
	}
}

[inline]
fn (g &Gen) nth_stmt_pos(n int) int {
	return g.stmt_path_pos[g.stmt_path_pos.len - (1 + n)]
}

fn (mut g Gen) go_before_stmt(n int) string {
	stmt_pos := g.nth_stmt_pos(n)
	cur_line := g.out.after(stmt_pos)
	g.out.go_back(cur_line.len)
	return cur_line
}

[inline]
fn (mut g Gen) go_before_ternary() string {
	return g.go_before_stmt(g.inside_ternary)
}

fn (mut g Gen) insert_before_stmt(s string) {
	cur_line := g.go_before_stmt(0)
	g.writeln(s)
	g.write(cur_line)
}

fn (mut g Gen) write_expr_to_string(expr ast.Expr) string {
	pos := g.out.buf.len
	g.expr(expr)
	return g.out.cut_last(g.out.buf.len - pos)
}

// fn (mut g Gen) start_tmp() {
// }
// If user is accessing the return value eg. in assigment, pass the variable name.
// If the user is not using the optional return value. We need to pass a temp var
// to access its fields (`.ok`, `.error` etc)
// `os.cp(...)` => `Option bool tmp = os__cp(...); if (!tmp.ok) { ... }`
// Returns the type of the last stmt
fn (mut g Gen) or_block(var_name string, or_block ast.OrExpr, return_type table.Type) {
	cvar_name := c_name(var_name)
	mr_styp := g.base_type(return_type)
	is_none_ok := mr_styp == 'void'
	g.writeln(';') // or')
	if is_none_ok {
		g.writeln('if (!${cvar_name}.ok && !${cvar_name}.is_none) {')
	} else {
		g.writeln('if (!${cvar_name}.ok) {')
	}
	if or_block.kind == .block {
		g.writeln('\tstring err = ${cvar_name}.v_error;')
		g.writeln('\tint errcode = ${cvar_name}.ecode;')
		stmts := or_block.stmts
		if stmts.len > 0 &&
			stmts[or_block.stmts.len - 1] is ast.ExprStmt &&
			(stmts[stmts.len - 1] as ast.ExprStmt).typ != table.void_type {
			g.indent++
			for i, stmt in stmts {
				if i == stmts.len - 1 {
					expr_stmt := stmt as ast.ExprStmt
					g.stmt_path_pos << g.out.len
					g.write('*($mr_styp*) ${cvar_name}.data = ')
					is_opt_call := expr_stmt.expr is ast.CallExpr && expr_stmt.typ.has_flag(.optional)
					if is_opt_call {
						g.write('*($mr_styp*) ')
					}
					g.expr(expr_stmt.expr)
					if is_opt_call {
						g.write('.data')
					}
					if g.inside_ternary == 0 && !(expr_stmt.expr is ast.IfExpr) {
						g.writeln(';')
					}
					g.stmt_path_pos.delete(g.stmt_path_pos.len - 1)
				} else {
					g.stmt(stmt)
				}
			}
			g.indent--
		} else {
			g.stmts(stmts)
		}
	} else if or_block.kind == .propagate {
		if g.file.mod.name == 'main' && g.fn_decl.name == 'main.main' {
			// In main(), an `opt()?` call is sugar for `opt() or { panic(err) }`
			if g.pref.is_debug {
				paline, pafile, pamod, pafn := g.panic_debug_info(or_block.pos)
				g.writeln('panic_debug($paline, tos3("$pafile"), tos3("$pamod"), tos3("$pafn"), ${cvar_name}.v_error );')
			} else {
				g.writeln('\tv_panic(${cvar_name}.v_error);')
			}
		} else {
			// In ordinary functions, `opt()?` call is sugar for:
			// `opt() or { return error(err) }`
			// Since we *do* return, first we have to ensure that
			// the defered statements are generated.
			g.write_defer_stmts()
			// Now that option types are distinct we need a cast here
			styp := g.typ(g.fn_decl.return_type)
			g.writeln('\treturn *($styp *)&$cvar_name;')
		}
	}
	g.write('}')
}

fn (mut g Gen) type_of_call_expr(node ast.Expr) string {
	match node {
		ast.CallExpr { return g.typ(node.return_type) }
		else { return typeof(node) }
	}
	return ''
}

// `a in [1,2,3]` => `a == 1 || a == 2 || a == 3`
fn (mut g Gen) in_optimization(left ast.Expr, right ast.ArrayInit) {
	is_str := right.elem_type == table.string_type
	elem_sym := g.table.get_type_symbol(right.elem_type)
	is_array := elem_sym.kind == .array
	for i, array_expr in right.exprs {
		if is_str {
			g.write('string_eq(')
		} else if is_array {
			ptr_typ := g.gen_array_equality_fn(right.elem_type)
			g.write('${ptr_typ}_arr_eq(')
		}
		g.expr(left)
		if is_str || is_array {
			g.write(', ')
		} else {
			g.write(' == ')
		}
		g.expr(array_expr)
		if is_str || is_array {
			g.write(')')
		}
		if i < right.exprs.len - 1 {
			g.write(' || ')
		}
	}
}

fn op_to_fn_name(name string) string {
	return match name {
		'+' { '_op_plus' }
		'-' { '_op_minus' }
		'*' { '_op_mul' }
		'/' { '_op_div' }
		'%' { '_op_mod' }
		else { 'bad op $name' }
	}
}

fn (mut g Gen) comp_if_to_ifdef(name string, is_comptime_optional bool) string {
	match name {
		// platforms/os-es:
		'windows' {
			return '_WIN32'
		}
		'mac' {
			return '__APPLE__'
		}
		'macos' {
			return '__APPLE__'
		}
		'mach' {
			return '__MACH__'
		}
		'darwin' {
			return '__DARWIN__'
		}
		'hpux' {
			return '__HPUX__'
		}
		'gnu' {
			return '__GNU__'
		}
		'qnx' {
			return '__QNX__'
		}
		'linux' {
			return '__linux__'
		}
		'freebsd' {
			return '__FreeBSD__'
		}
		'openbsd' {
			return '__OpenBSD__'
		}
		'netbsd' {
			return '__NetBSD__'
		}
		'bsd' {
			return '__BSD__'
		}
		'dragonfly' {
			return '__DragonFly__'
		}
		'android' {
			return '__ANDROID__'
		}
		'solaris' {
			return '__sun'
		}
		'haiku' {
			return '__haiku__'
		}
		'linux_or_macos' {
			return ''
		}
		//
		'js' {
			return '_VJS'
		}
		// compilers:
		'tinyc' {
			return '__TINYC__'
		}
		'clang' {
			return '__clang__'
		}
		'mingw' {
			return '__MINGW32__'
		}
		'msvc' {
			return '_MSC_VER'
		}
		'cplusplus' {
			return '__cplusplus'
		}
		// other:
		'debug' {
			return '_VDEBUG'
		}
		'test' {
			return '_VTEST'
		}
		'glibc' {
			return '__GLIBC__'
		}
		'prealloc' {
			return '_VPREALLOC'
		}
		'no_bounds_checking' {
			return 'CUSTOM_DEFINE_no_bounds_checking'
		}
		'x64' {
			return 'TARGET_IS_64BIT'
		}
		'x32' {
			return 'TARGET_IS_32BIT'
		}
		'little_endian' {
			return 'TARGET_ORDER_IS_LITTLE'
		}
		'big_endian' {
			return 'TARGET_ORDER_IS_BIG'
		}
		else {
			if is_comptime_optional || (g.pref.compile_defines_all.len > 0 &&
				name in g.pref.compile_defines_all) {
				return 'CUSTOM_DEFINE_$name'
			}
			verror('bad os ifdef name "$name"')
		}
	}
	// verror('bad os ifdef name "$name"')
	return ''
}

[inline]
fn c_name(name_ string) string {
	name := util.no_dots(name_)
	if name in c_reserved {
		return 'v_$name'
	}
	return name
}

fn (g Gen) type_default(typ table.Type) string {
	sym := g.table.get_type_symbol(typ)
	if sym.kind == .array {
		elem_sym := g.typ(sym.array_info().elem_type)
		mut elem_type_str := util.no_dots(elem_sym)
		if elem_type_str.starts_with('C__') {
			elem_type_str = elem_type_str[3..]
		}
		return '__new_array(0, 1, sizeof($elem_type_str))'
	}
	if sym.kind == .map {
		value_type_str := g.typ(sym.map_info().value_type)
		return 'new_map_1(sizeof($value_type_str))'
	}
	// Always set pointers to 0
	if typ.is_ptr() {
		return '0'
	}
	// User struct defined in another module.
	// if typ.contains('__') {
	if sym.kind == .struct_ {
		return '{0}'
	}
	// if typ.ends_with('Fn') { // TODO
	// return '0'
	// }
	// Default values for other types are not needed because of mandatory initialization
	idx := int(typ)
	if idx >= 1 && idx <= 17 {
		return '0'
	}
	/*
	match idx {
		table.bool_type_idx {
			return '0'
		}
		else {}
	}
	*/
	match sym.name {
		'string' { return '(string){.str=(byteptr)""}' }
		'rune' { return '0' }
		else {}
	}
	return match sym.kind {
		.sum_type { '{0}' }
		.array_fixed { '{0}' }
		else { '0' }
	}
	// TODO this results in
	// error: expected a field designator, such as '.field = 4'
	// - Empty ee= (Empty) { . =  {0}  } ;
	/*
	return match typ {
	'bool'{ '0'}
	'string'{ 'tos_lit("")'}
	'i8'{ '0'}
	'i16'{ '0'}
	'i64'{ '0'}
	'u16'{ '0'}
	'u32'{ '0'}
	'u64'{ '0'}
	'byte'{ '0'}
	'int'{ '0'}
	'rune'{ '0'}
	'f32'{ '0.0'}
	'f64'{ '0.0'}
	'byteptr'{ '0'}
	'voidptr'{ '0'}
	else { '{0} '}
}
	*/
}

fn (g Gen) get_all_test_function_names() []string {
	mut tfuncs := []string{}
	mut tsuite_begin := ''
	mut tsuite_end := ''
	for _, f in g.table.fns {
		if f.name == 'testsuite_begin' {
			tsuite_begin = f.name
			continue
		}
		if f.name == 'testsuite_end' {
			tsuite_end = f.name
			continue
		}
		if f.name.starts_with('test_') {
			tfuncs << f.name
			continue
		}
		// What follows is for internal module tests
		// (they are part of a V module, NOT in main)
		if f.name.contains('.test_') {
			tfuncs << f.name
			continue
		}
		if f.name.ends_with('.testsuite_begin') {
			tsuite_begin = f.name
			continue
		}
		if f.name.ends_with('.testsuite_end') {
			tsuite_end = f.name
			continue
		}
	}
	mut all_tfuncs := []string{}
	if tsuite_begin.len > 0 {
		all_tfuncs << tsuite_begin
	}
	all_tfuncs << tfuncs
	if tsuite_end.len > 0 {
		all_tfuncs << tsuite_end
	}
	mut all_tfuncs_c := []string{}
	for f in all_tfuncs {
		all_tfuncs_c << util.no_dots(f)
	}
	return all_tfuncs_c
}

fn (g Gen) is_importing_os() bool {
	return 'os' in g.table.imports
}

fn (mut g Gen) go_stmt(node ast.GoStmt) {
	tmp := g.new_tmp_var()
	expr := node.call_expr as ast.CallExpr
	mut name := expr.name // util.no_dots(expr.name)
	if expr.is_method {
		receiver_sym := g.table.get_type_symbol(expr.receiver_type)
		name = receiver_sym.name + '_' + name
	}
	name = util.no_dots(name)
	g.writeln('// go')
	wrapper_struct_name := 'thread_arg_' + name
	wrapper_fn_name := name + '_thread_wrapper'
	arg_tmp_var := 'arg_' + tmp
	g.writeln('$wrapper_struct_name *$arg_tmp_var = malloc(sizeof(thread_arg_$name));')
	if expr.is_method {
		g.write('$arg_tmp_var->arg0 = ')
		// TODO is this needed?
		/*
		if false && !expr.return_type.is_ptr() {
			g.write('&')
		}
		*/
		g.expr(expr.left)
		g.writeln(';')
	}
	for i, arg in expr.args {
		g.write('$arg_tmp_var->arg${i+1} = ')
		g.expr(arg.expr)
		g.writeln(';')
	}
	if g.pref.os == .windows {
		g.writeln('CreateThread(0,0, (LPTHREAD_START_ROUTINE)$wrapper_fn_name, $arg_tmp_var, 0,0);')
	} else {
		g.writeln('pthread_t thread_$tmp;')
		g.writeln('pthread_create(&thread_$tmp, NULL, (void*)$wrapper_fn_name, $arg_tmp_var);')
	}
	g.writeln('// endgo\n')
	// Register the wrapper type and function
	if name in g.threaded_fns {
		return
	}
	g.type_definitions.writeln('\ntypedef struct $wrapper_struct_name {')
	if expr.is_method {
		styp := g.typ(expr.receiver_type)
		g.type_definitions.writeln('\t$styp arg0;')
	}
	if expr.args.len == 0 {
		g.type_definitions.writeln('EMPTY_STRUCT_DECLARATION;')
	} else {
		for i, arg in expr.args {
			styp := g.typ(arg.typ)
			g.type_definitions.writeln('\t$styp arg${i+1};')
		}
	}
	g.type_definitions.writeln('} $wrapper_struct_name;')
	g.type_definitions.writeln('void* ${wrapper_fn_name}($wrapper_struct_name *arg);')
	g.gowrappers.writeln('void* ${wrapper_fn_name}($wrapper_struct_name *arg) {')
	g.gowrappers.write('\t${name}(')
	if expr.is_method {
		g.gowrappers.write('arg->arg0')
		if expr.args.len > 0 {
			g.gowrappers.write(', ')
		}
	}
	for i in 0 .. expr.args.len {
		g.gowrappers.write('arg->arg${i+1}')
		if i < expr.args.len - 1 {
			g.gowrappers.write(', ')
		}
	}
	g.gowrappers.writeln(');')
	g.gowrappers.writeln('\treturn 0;')
	g.gowrappers.writeln('}')
	g.threaded_fns << name
}

fn (mut g Gen) as_cast(node ast.AsCast) {
	// Make sure the sum type can be cast to this type (the types
	// are the same), otherwise panic.
	// g.insert_before('
	styp := g.typ(node.typ)
	expr_type_sym := g.table.get_type_symbol(node.expr_type)
	if expr_type_sym.kind == .sum_type {
		/*
		g.write('*($styp*)')
		g.expr(node.expr)
		g.write('.obj')
		*/
		dot := if node.expr_type.is_ptr() { '->' } else { '.' }
		g.write('/* as */ ($styp*)__as_cast(')
		g.expr(node.expr)
		g.write(dot)
		g.write('obj, ')
		g.expr(node.expr)
		g.write(dot)
		g.write('typ, /*expected:*/$node.typ)')
	}
}

fn (mut g Gen) is_expr(node ast.InfixExpr) {
	eq := if node.op == .key_is { '==' } else { '!=' }
	g.expr(node.left)
	if node.left_type.is_ptr() {
		g.write('->')
	} else {
		g.write('.')
	}
	sym := g.table.get_type_symbol(node.left_type)
	if sym.kind == .interface_ {
		g.write('_interface_idx $eq ')
		// `_Animal_Dog_index`
		sub_type := node.right as ast.Type
		sub_sym := g.table.get_type_symbol(sub_type.typ)
		g.write('_${c_name(sym.name)}_${c_name(sub_sym.name)}_index')
		return
	} else if sym.kind == .sum_type {
		g.write('typ $eq ')
	}
	g.expr(node.right)
}

[inline]
fn styp_to_str_fn_name(styp string) string {
	return styp.replace('*', '_ptr') + '_str'
}

[inline]
fn (mut g Gen) gen_str_for_type(typ table.Type) string {
	if g.pref.build_mode == .build_module {
		return ''
	}
	styp := g.typ(typ)
	return g.gen_str_for_type_with_styp(typ, styp)
}

// already generated styp, reuse it
fn (mut g Gen) gen_str_for_type_with_styp(typ table.Type, styp string) string {
	sym := g.table.get_type_symbol(typ)
	str_fn_name := styp_to_str_fn_name(styp)
	sym_has_str_method, str_method_expects_ptr, str_nr_args := sym.str_method_info()
	// generate for type
	if sym_has_str_method && str_method_expects_ptr && str_nr_args == 1 {
		// TODO: optimize out this.
		// It is needed, so that println() can be called with &T and T has `fn (t &T).str() string`
		/*
		eprintln('>> gsftws: typ: $typ | typ_is_ptr $typ_is_ptr | styp: $styp ' +
			'| $str_fn_name | sym.name: $sym.name has_str: $sym_has_str_method ' +
			'| expects_ptr: $str_method_expects_ptr')
		*/
		str_fn_name_no_ptr := '${str_fn_name}_no_ptr'
		already_generated_key_no_ptr := '$styp:$str_fn_name_no_ptr'
		if already_generated_key_no_ptr !in g.str_types {
			g.str_types << already_generated_key_no_ptr
			g.type_definitions.writeln('string ${str_fn_name_no_ptr}($styp it); // auto no_ptr version')
			g.auto_str_funcs.writeln('string ${str_fn_name_no_ptr}($styp it){ return ${str_fn_name}(&it); }')
		}
		/*
		typ_is_ptr := typ.is_ptr()
		ret_type := if typ_is_ptr { str_fn_name } else { str_fn_name_no_ptr }
		eprintln('    ret_type: $ret_type')
		return ret_type
		*/
		return str_fn_name_no_ptr
	}
	already_generated_key := '$styp:$str_fn_name'
	if !sym_has_str_method && already_generated_key !in g.str_types {
		$if debugautostr ? {
			eprintln('> gen_str_for_type_with_styp: |typ: ${typ:5}, ${sym.name:20}|has_str: ${sym_has_str_method:5}|expects_ptr: ${str_method_expects_ptr:5}|nr_args: ${str_nr_args:1}|fn_name: ${str_fn_name:20}')
		}
		g.str_types << already_generated_key
		match sym.info {
			table.Alias { g.gen_str_default(sym, styp, str_fn_name) }
			table.Array { g.gen_str_for_array(it, styp, str_fn_name) }
			table.ArrayFixed { g.gen_str_for_array_fixed(it, styp, str_fn_name) }
			table.Enum { g.gen_str_for_enum(it, styp, str_fn_name) }
			table.Struct { g.gen_str_for_struct(it, styp, str_fn_name) }
			table.Map { g.gen_str_for_map(it, styp, str_fn_name) }
			table.MultiReturn { g.gen_str_for_multi_return(it, styp, str_fn_name) }
			else { verror("could not generate string method $str_fn_name for type \'$styp\'") }
		}
	}
	// if varg, generate str for varg
	if typ.has_flag(.variadic) {
		varg_already_generated_key := 'varg_$already_generated_key'
		if varg_already_generated_key !in g.str_types {
			g.gen_str_for_varg(styp, str_fn_name, sym_has_str_method)
			g.str_types << varg_already_generated_key
		}
		return 'varg_$str_fn_name'
	}
	return str_fn_name
}

fn (mut g Gen) gen_str_default(sym table.TypeSymbol, styp, str_fn_name string) {
	mut convertor := ''
	mut typename_ := ''
	if sym.parent_idx in table.integer_type_idxs {
		convertor = 'int'
		typename_ = 'int'
	} else if sym.parent_idx == table.f32_type_idx {
		convertor = 'float'
		typename_ = 'f32'
	} else if sym.parent_idx == table.f64_type_idx {
		convertor = 'double'
		typename_ = 'f64'
	} else if sym.parent_idx == table.bool_type_idx {
		convertor = 'bool'
		typename_ = 'bool'
	} else {
		verror("could not generate string method for type \'$styp\'")
	}
	g.type_definitions.writeln('string ${str_fn_name}($styp it); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp it) {')
	if convertor == 'bool' {
		g.auto_str_funcs.writeln('\tstring tmp1 = string_add(tos_lit("${styp}("), ($convertor)it ? tos_lit("true") : tos_lit("false"));')
	} else {
		g.auto_str_funcs.writeln('\tstring tmp1 = string_add(tos_lit("${styp}("), tos3(${typename_}_str(($convertor)it).str));')
	}
	g.auto_str_funcs.writeln('\tstring tmp2 = string_add(tmp1, tos_lit(")"));')
	g.auto_str_funcs.writeln('\tstring_free(&tmp1);')
	g.auto_str_funcs.writeln('\treturn tmp2;')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_enum(info table.Enum, styp, str_fn_name string) {
	s := util.no_dots(styp)
	g.type_definitions.writeln('string ${str_fn_name}($styp it); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp it) { /* gen_str_for_enum */')
	g.auto_str_funcs.writeln('\tswitch(it) {')
	// Only use the first multi value on the lookup
	mut seen := []string{len: info.vals.len}
	for val in info.vals {
		if info.is_multi_allowed && val in seen {
			continue
		} else if info.is_multi_allowed {
			seen << val
		}
		g.auto_str_funcs.writeln('\t\tcase ${s}_$val: return tos_lit("$val");')
	}
	g.auto_str_funcs.writeln('\t\tdefault: return tos_lit("unknown enum value");')
	g.auto_str_funcs.writeln('\t}')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_struct(info table.Struct, styp, str_fn_name string) {
	// TODO: short it if possible
	// generates all definitions of substructs
	mut fnames2strfunc := {
		'': ''
	} // map[string]string // TODO vfmt bug
	for field in info.fields {
		sym := g.table.get_type_symbol(field.typ)
		if !sym.has_method('str') {
			field_styp := g.typ(field.typ)
			field_fn_name := g.gen_str_for_type_with_styp(field.typ, field_styp)
			fnames2strfunc[field_styp] = field_fn_name
		}
	}
	// _str() functions should have a single argument, the indenting ones take 2:
	g.type_definitions.writeln('string ${str_fn_name}($styp x); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp x) { return indent_${str_fn_name}(x,0);}')
	//
	g.type_definitions.writeln('string indent_${str_fn_name}($styp x, int indent_count); // auto')
	g.auto_str_funcs.writeln('string indent_${str_fn_name}($styp x, int indent_count) {')
	mut clean_struct_v_type_name := styp.replace('__', '.')
	if styp.ends_with('*') {
		deref_typ := styp.replace('*', '')
		g.auto_str_funcs.writeln('\t$deref_typ *it = x;')
		clean_struct_v_type_name = '&' + clean_struct_v_type_name.replace('*', '')
	} else {
		deref_typ := styp
		g.auto_str_funcs.writeln('\t$deref_typ *it = &x;')
	}
	clean_struct_v_type_name = util.strip_main_name(clean_struct_v_type_name)
	// generate ident / indent length = 4 spaces
	g.auto_str_funcs.writeln('\tstring indents = tos_lit("");')
	g.auto_str_funcs.writeln('\tfor (int i = 0; i < indent_count; ++i) {')
	g.auto_str_funcs.writeln('\t\tindents = string_add(indents, tos_lit("    "));')
	g.auto_str_funcs.writeln('\t}')
	g.auto_str_funcs.writeln('\treturn _STR("$clean_struct_v_type_name {\\n"')
	for field in info.fields {
		fmt := g.type_to_fmt(field.typ)
		g.auto_str_funcs.writeln('\t\t"%.*s\\000    ' + '$field.name: $fmt\\n"')
	}
	g.auto_str_funcs.write('\t\t"%.*s\\000}", ${2*(info.fields.len+1)}')
	if info.fields.len > 0 {
		g.auto_str_funcs.write(',\n\t\t')
		for i, field in info.fields {
			sym := g.table.get_type_symbol(field.typ)
			has_custom_str := sym.has_method('str')
			mut field_styp := g.typ(field.typ)
			if field_styp.ends_with('*') {
				field_styp = field_styp.replace('*', '')
			}
			field_styp_fn_name := if has_custom_str { '${field_styp}_str' } else { fnames2strfunc[field_styp] }
			if sym.kind == .enum_ {
				g.auto_str_funcs.write('indents, ')
				g.auto_str_funcs.write('${field_styp_fn_name}( it->${c_name(field.name)} ) ')
			} else if sym.kind == .struct_ {
				g.auto_str_funcs.write('indents, ')
				if has_custom_str {
					g.auto_str_funcs.write('${field_styp_fn_name}( it->${c_name(field.name)} ) ')
				} else {
					g.auto_str_funcs.write('indent_${field_styp_fn_name}( it->${c_name(field.name)}, indent_count + 1 ) ')
				}
			} else if sym.kind in [.array, .array_fixed, .map] {
				g.auto_str_funcs.write('indents, ')
				g.auto_str_funcs.write('${field_styp_fn_name}( it->${c_name(field.name)}) ')
			} else {
				g.auto_str_funcs.write('indents, it->${c_name(field.name)}')
				if field.typ == table.bool_type {
					g.auto_str_funcs.write(' ? _SLIT("true") : _SLIT("false")')
				}
			}
			if i < info.fields.len - 1 {
				g.auto_str_funcs.write(',\n\t\t')
			}
		}
	}
	g.auto_str_funcs.writeln(',')
	g.auto_str_funcs.writeln('\t\tindents);')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_array(info table.Array, styp, str_fn_name string) {
	sym := g.table.get_type_symbol(info.elem_type)
	field_styp := g.typ(info.elem_type)
	is_elem_ptr := info.elem_type.is_ptr()
	sym_has_str_method, str_method_expects_ptr, _ := sym.str_method_info()
	mut elem_str_fn_name := ''
	if sym_has_str_method {
		elem_str_fn_name = if is_elem_ptr { field_styp.replace('*', '') + '_str' } else { field_styp +
				'_str' }
	} else {
		elem_str_fn_name = styp_to_str_fn_name(field_styp)
	}
	if !sym_has_str_method {
		// eprintln('> sym.name: does not have method `str`')
		g.gen_str_for_type_with_styp(info.elem_type, field_styp)
	}
	g.type_definitions.writeln('string ${str_fn_name}($styp a); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp a) {')
	g.auto_str_funcs.writeln('\tstrings__Builder sb = strings__new_builder(a.len * 10);')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("["));')
	g.auto_str_funcs.writeln('\tfor (int i = 0; i < a.len; ++i) {')
	g.auto_str_funcs.writeln('\t\t$field_styp it = (*($field_styp*)array_get(a, i));')
	if sym.kind == .struct_ && !sym_has_str_method {
		if is_elem_ptr {
			g.auto_str_funcs.writeln('\t\tstring x = ${elem_str_fn_name}(*it);')
		} else {
			g.auto_str_funcs.writeln('\t\tstring x = ${elem_str_fn_name}(it);')
		}
	} else if sym.kind in [.f32, .f64] {
		g.auto_str_funcs.writeln('\t\tstring x = _STR("%g", 1, it);')
	} else {
		// There is a custom .str() method, so use it.
		// NB: we need to take account of whether the user has defined
		// `fn (x T) str() {` or `fn (x &T) str() {`, and convert accordingly
		if (str_method_expects_ptr && is_elem_ptr) || (!str_method_expects_ptr && !is_elem_ptr) {
			g.auto_str_funcs.writeln('\t\tstring x = ${elem_str_fn_name}(it);')
		} else if str_method_expects_ptr && !is_elem_ptr {
			g.auto_str_funcs.writeln('\t\tstring x = ${elem_str_fn_name}(&it);')
		} else if !str_method_expects_ptr && is_elem_ptr {
			g.auto_str_funcs.writeln('\t\tstring x = ${elem_str_fn_name}(*it);')
		}
	}
	g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, x);')
	if g.pref.autofree && info.elem_type != table.bool_type {
		// no need to free "true"/"false" literals
		g.auto_str_funcs.writeln('\t\tstring_free(&x);')
	}
	g.auto_str_funcs.writeln('\t\tif (i < a.len-1) {')
	g.auto_str_funcs.writeln('\t\t\tstrings__Builder_write(&sb, tos_lit(", "));')
	g.auto_str_funcs.writeln('\t\t}')
	g.auto_str_funcs.writeln('\t}')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("]"));')
	g.auto_str_funcs.writeln('\tstring res = strings__Builder_str(&sb);')
	g.auto_str_funcs.writeln('\tstrings__Builder_free(&sb);')
	// g.auto_str_funcs.writeln('\treturn strings__Builder_str(&sb);')
	g.auto_str_funcs.writeln('\treturn res;')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_array_fixed(info table.ArrayFixed, styp, str_fn_name string) {
	sym := g.table.get_type_symbol(info.elem_type)
	field_styp := g.typ(info.elem_type)
	is_elem_ptr := info.elem_type.is_ptr()
	sym_has_str_method, str_method_expects_ptr, _ := sym.str_method_info()
	mut elem_str_fn_name := ''
	if sym_has_str_method {
		elem_str_fn_name = if is_elem_ptr { field_styp.replace('*', '') + '_str' } else { field_styp +
				'_str' }
	} else {
		elem_str_fn_name = styp_to_str_fn_name(field_styp)
	}
	if !sym.has_method('str') {
		g.gen_str_for_type_with_styp(info.elem_type, field_styp)
	}
	g.type_definitions.writeln('string ${str_fn_name}($styp a); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp a) {')
	g.auto_str_funcs.writeln('\tstrings__Builder sb = strings__new_builder($info.size * 10);')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("["));')
	g.auto_str_funcs.writeln('\tfor (int i = 0; i < $info.size; ++i) {')
	if sym.kind == .struct_ && !sym_has_str_method {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${elem_str_fn_name}(a[i]));')
	} else if sym.kind in [.f32, .f64] {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, _STR("%g", 1, a[i]));')
	} else if sym.kind == .string {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, _STR("\'%.*s\\000\'", 2, a[i]));')
	} else {
		if (str_method_expects_ptr && is_elem_ptr) || (!str_method_expects_ptr && !is_elem_ptr) {
			g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${elem_str_fn_name}(a[i]));')
		} else if str_method_expects_ptr && !is_elem_ptr {
			g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${elem_str_fn_name}(&a[i]));')
		} else if !str_method_expects_ptr && is_elem_ptr {
			g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${elem_str_fn_name}(*a[i]));')
		}
	}
	g.auto_str_funcs.writeln('\t\tif (i < ${info.size-1}) {')
	g.auto_str_funcs.writeln('\t\t\tstrings__Builder_write(&sb, tos_lit(", "));')
	g.auto_str_funcs.writeln('\t\t}')
	g.auto_str_funcs.writeln('\t}')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("]"));')
	g.auto_str_funcs.writeln('\treturn strings__Builder_str(&sb);')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_map(info table.Map, styp, str_fn_name string) {
	key_sym := g.table.get_type_symbol(info.key_type)
	key_styp := g.typ(info.key_type)
	if !key_sym.has_method('str') {
		g.gen_str_for_type_with_styp(info.key_type, key_styp)
	}
	val_sym := g.table.get_type_symbol(info.value_type)
	val_styp := g.typ(info.value_type)
	elem_str_fn_name := val_styp.replace('*', '') + '_str'
	if !val_sym.has_method('str') {
		g.gen_str_for_type_with_styp(info.value_type, val_styp)
	}
	zero := g.type_default(info.value_type)
	g.type_definitions.writeln('string ${str_fn_name}($styp m); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp m) { /* gen_str_for_map */')
	g.auto_str_funcs.writeln('\tstrings__Builder sb = strings__new_builder(m.key_values.len*10);')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("{"));')
	g.auto_str_funcs.writeln('\tfor (unsigned int i = 0; i < m.key_values.len; ++i) {')
	g.auto_str_funcs.writeln('\t\tstring key = (*(string*)DenseArray_get(m.key_values, i));')
	g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, _STR("\'%.*s\\000\'", 2, key));')
	g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, tos_lit(": "));')
	g.auto_str_funcs.write('\t$val_styp it = (*($val_styp*)map_get(')
	g.auto_str_funcs.write('m, (*(string*)DenseArray_get(m.key_values, i))')
	g.auto_str_funcs.write(', ')
	g.auto_str_funcs.writeln(' &($val_styp[]) { $zero }));')
	if val_sym.kind == .string {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, _STR("\'%.*s\\000\'", 2, it));')
	} else if val_sym.kind == .struct_ && !val_sym.has_method('str') {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${elem_str_fn_name}(it));')
	} else if val_sym.kind in [.f32, .f64] {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, _STR("%g", 1, it));')
	} else {
		g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${elem_str_fn_name}(it));')
	}
	g.auto_str_funcs.writeln('\t\tif (i != m.key_values.len-1) {')
	g.auto_str_funcs.writeln('\t\t\tstrings__Builder_write(&sb, tos_lit(", "));')
	g.auto_str_funcs.writeln('\t\t}')
	g.auto_str_funcs.writeln('\t}')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("}"));')
	g.auto_str_funcs.writeln('\treturn strings__Builder_str(&sb);')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_varg(styp, str_fn_name string, has_str_method bool) {
	g.definitions.writeln('string varg_${str_fn_name}(varg_$styp it); // auto')
	g.auto_str_funcs.writeln('string varg_${str_fn_name}(varg_$styp it) {')
	g.auto_str_funcs.writeln('\tstrings__Builder sb = strings__new_builder(it.len);')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("["));')
	g.auto_str_funcs.writeln('\tfor(int i=0; i<it.len; ++i) {')
	g.auto_str_funcs.writeln('\t\tstrings__Builder_write(&sb, ${str_fn_name}(it.args[i]));')
	g.auto_str_funcs.writeln('\t\tif (i < it.len-1) {')
	g.auto_str_funcs.writeln('\t\t\tstrings__Builder_write(&sb, tos_lit(", "));')
	g.auto_str_funcs.writeln('\t\t}')
	g.auto_str_funcs.writeln('\t}')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("]"));')
	g.auto_str_funcs.writeln('\treturn strings__Builder_str(&sb);')
	g.auto_str_funcs.writeln('}')
}

fn (mut g Gen) gen_str_for_multi_return(info table.MultiReturn, styp, str_fn_name string) {
	for typ in info.types {
		sym := g.table.get_type_symbol(typ)
		if !sym.has_method('str') {
			field_styp := g.typ(typ)
			g.gen_str_for_type_with_styp(typ, field_styp)
		}
	}
	g.type_definitions.writeln('string ${str_fn_name}($styp a); // auto')
	g.auto_str_funcs.writeln('string ${str_fn_name}($styp a) {')
	g.auto_str_funcs.writeln('\tstrings__Builder sb = strings__new_builder($info.types.len * 10);')
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit("("));')
	for i, typ in info.types {
		sym := g.table.get_type_symbol(typ)
		field_styp := g.typ(typ)
		is_arg_ptr := typ.is_ptr()
		sym_has_str_method, str_method_expects_ptr, _ := sym.str_method_info()
		mut arg_str_fn_name := ''
		if sym_has_str_method {
			arg_str_fn_name = if is_arg_ptr { field_styp.replace('*', '') + '_str' } else { field_styp +
					'_str' }
		} else {
			arg_str_fn_name = styp_to_str_fn_name(field_styp)
		}
		if sym.kind == .struct_ && !sym_has_str_method {
			g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, ${str_fn_name}(a.arg$i));')
		} else if sym.kind in [.f32, .f64] {
			g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, _STR("%g", 1, a.arg$i));')
		} else if sym.kind == .string {
			g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, _STR("\'%.*s\\000\'", 2, a.arg$i));')
		} else {
			if (str_method_expects_ptr && is_arg_ptr) || (!str_method_expects_ptr && !is_arg_ptr) {
				g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, ${arg_str_fn_name}(a.arg$i));')
			} else if str_method_expects_ptr && !is_arg_ptr {
				g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, ${arg_str_fn_name}(&a.arg$i));')
			} else if !str_method_expects_ptr && is_arg_ptr {
				g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, ${arg_str_fn_name}(*a.arg$i));')
			}
		}
		if i != info.types.len - 1 {
			g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit(", "));')
		}
	}
	g.auto_str_funcs.writeln('\tstrings__Builder_write(&sb, tos_lit(")"));')
	g.auto_str_funcs.writeln('\treturn strings__Builder_str(&sb);')
	g.auto_str_funcs.writeln('}')
}

fn (g Gen) type_to_fmt(typ table.Type) string {
	sym := g.table.get_type_symbol(typ)
	if sym.kind in [.struct_, .array, .array_fixed, .map] {
		return '%.*s\\000'
	} else if typ == table.string_type {
		return "\'%.*s\\000\'"
	} else if typ == table.bool_type {
		return '%.*s\\000'
	} else if sym.kind == .enum_ {
		return '%.*s\\000'
	} else if typ in [table.f32_type, table.f64_type] {
		return '%g\\000' // g removes trailing zeros unlike %f
	}
	return '%d\\000'
}

// Generates interface table and interface indexes
fn (g &Gen) interface_table() string {
	mut sb := strings.new_builder(100)
	for ityp in g.table.types {
		if ityp.kind != .interface_ {
			continue
		}
		inter_info := ityp.info as table.Interface
		if inter_info.types.len == 0 {
			continue
		}
		sb.writeln('// NR interfaced types= $inter_info.types.len')
		// interface_name is for example Speaker
		interface_name := c_name(ityp.name)
		// generate a struct that references interface methods
		methods_struct_name := 'struct _${interface_name}_interface_methods'
		mut methods_typ_def := strings.new_builder(100)
		mut methods_struct_def := strings.new_builder(100)
		methods_struct_def.writeln('$methods_struct_name {')
		mut imethods := map[string]string{} // a map from speak -> _Speaker_speak_fn
		mut methodidx := map[string]int{}
		for k, method in ityp.methods {
			methodidx[method.name] = k
			typ_name := '_${interface_name}_${method.name}_fn'
			ret_styp := g.typ(method.return_type)
			methods_typ_def.write('typedef $ret_styp (*$typ_name)(void* _')
			// the first param is the receiver, it's handled by `void*` above
			for i in 1 .. method.args.len {
				arg := method.args[i]
				methods_typ_def.write(', ${g.typ(arg.typ)} $arg.name')
			}
			// TODO g.fn_args(method.args[1..], method.is_variadic)
			methods_typ_def.writeln(');')
			methods_struct_def.writeln('\t$typ_name ${c_name(method.name)};')
			imethods[method.name] = typ_name
		}
		methods_struct_def.writeln('};')
		// generate an array of the interface methods for the structs using the interface
		// as well as case functions from the struct to the interface
		mut methods_struct := strings.new_builder(100)
		methods_struct.writeln('$methods_struct_name ${interface_name}_name_table[$inter_info.types.len] = {')
		mut cast_functions := strings.new_builder(100)
		cast_functions.write('// Casting functions for interface "$interface_name"')
		mut methods_wrapper := strings.new_builder(100)
		methods_wrapper.writeln('// Methods wrapper for interface "$interface_name"')
		for i, st in inter_info.types {
			// cctype is the Cleaned Concrete Type name, *without ptr*,
			// i.e. cctype is always just Cat, not Cat_ptr:
			cctype := g.cc_type(st)
			// Speaker_Cat_index = 0
			interface_index_name := '_${interface_name}_${cctype}_index'
			cast_functions.writeln('
_Interface I_${cctype}_to_Interface_${interface_name}($cctype* x) {
	return (_Interface) {
		._object = (void*) (x),
		._interface_idx = $interface_index_name
	};
}

_Interface* I_${cctype}_to_Interface_${interface_name}_ptr($cctype* x) {
	/* TODO Remove memdup */
	return (_Interface*) memdup(&(_Interface) {
		._object = (void*) (x),
		._interface_idx = $interface_index_name
	}, sizeof(_Interface));
}')
			methods_struct.writeln('\t{')
			st_sym := g.table.get_type_symbol(st)
			mut method := table.Fn{}
			for _, m in ityp.methods {
				for mm in st_sym.methods {
					if mm.name == m.name {
						method = mm
						break
					}
				}
				if method.name !in imethods {
					// a method that is not part of the interface should be just skipped
					continue
				}
				// .speak = Cat_speak
				mut method_call := '${cctype}_$method.name'
				if !method.args[0].typ.is_ptr() {
					// inline void Cat_speak_method_wrapper(Cat c) { return Cat_speak(*c); }
					methods_wrapper.write('static inline ${g.typ(method.return_type)}')
					methods_wrapper.write(' ${method_call}_method_wrapper(')
					methods_wrapper.write('$cctype* ${method.args[0].name}')
					// TODO g.fn_args
					for j in 1 .. method.args.len {
						arg := method.args[j]
						methods_wrapper.write(', ${g.typ(arg.typ)} $arg.name')
					}
					methods_wrapper.writeln(') {')
					methods_wrapper.write('\t')
					if method.return_type != table.void_type {
						methods_wrapper.write('return ')
					}
					methods_wrapper.write('${method_call}(*${method.args[0].name}')
					for j in 1 .. method.args.len {
						methods_wrapper.write(', ${method.args[j].name}')
					}
					methods_wrapper.writeln(');')
					methods_wrapper.writeln('}')
					// .speak = Cat_speak_method_wrapper
					method_call += '_method_wrapper'
				}
				methods_struct.writeln('\t\t.${c_name(method.name)} = $method_call,')
			}
			methods_struct.writeln('\t},')
			sb.writeln('int $interface_index_name = $i;')
		}
		methods_struct.writeln('};')
		// add line return after interface index declarations
		sb.writeln('')
		sb.writeln(methods_wrapper.str())
		sb.writeln(methods_typ_def.str())
		sb.writeln(methods_struct_def.str())
		sb.writeln(methods_struct.str())
		sb.writeln(cast_functions.str())
	}
	return sb.str()
}

fn (mut g Gen) array_init(it ast.ArrayInit) {
	type_sym := g.table.get_type_symbol(it.typ)
	styp := g.typ(it.typ)
	mut shared_styp := '' // only needed for shared &[]{...}
	is_amp := g.is_amp
	g.is_amp = false
	if is_amp {
		g.out.go_back(1) // delete the `&` already generated in `prefix_expr()
		if g.is_shared {
			mut shared_typ := it.typ.set_flag(.shared_f)
			shared_styp = g.typ(shared_typ)
			g.writeln('($shared_styp*)memdup(&($shared_styp){.val = ')
		} else {
			g.write('($styp*)memdup(&') // TODO: doesn't work with every compiler
		}
	} else {
		if g.is_shared {
			g.writeln('{.val = ($styp*)')
		}
	}
	if type_sym.kind == .array_fixed {
		g.write('{')
		for i, expr in it.exprs {
			g.expr(expr)
			if i != it.exprs.len - 1 {
				g.write(', ')
			}
		}
		g.write('}')
		return
	}
	elem_type_str := g.typ(it.elem_type)
	if it.exprs.len == 0 {
		elem_sym := g.table.get_type_symbol(it.elem_type)
		is_default_array := elem_sym.kind == .array && it.has_default
		if is_default_array {
			g.write('__new_array_with_array_default(')
		} else {
			g.write('__new_array_with_default(')
		}
		if it.has_len {
			g.expr(it.len_expr)
			g.write(', ')
		} else {
			g.write('0, ')
		}
		if it.has_cap {
			g.expr(it.cap_expr)
			g.write(', ')
		} else {
			g.write('0, ')
		}
		g.write('sizeof($elem_type_str), ')
		if is_default_array {
			g.write('($elem_type_str[]){')
			g.expr(it.default_expr)
			g.write('}[0])')
		} else if it.has_default {
			g.write('&($elem_type_str[]){')
			g.expr(it.default_expr)
			g.write('})')
		} else if it.has_len && it.elem_type == table.string_type {
			g.write('&($elem_type_str[]){')
			g.write('tos_lit("")')
			g.write('})')
		} else {
			g.write('0)')
		}
		return
	}
	len := it.exprs.len
	g.write('new_array_from_c_array($len, $len, sizeof($elem_type_str), _MOV(($elem_type_str[$len]){')
	if len > 8 {
		g.writeln('')
		g.write('\t\t')
	}
	for i, expr in it.exprs {
		if it.is_interface {
			// sym := g.table.get_type_symbol(it.interface_types[i])
			// isym := g.table.get_type_symbol(it.interface_type)
			g.interface_call(it.interface_types[i], it.interface_type)
		}
		g.expr(expr)
		if it.is_interface {
			g.write(')')
		}
		if i != len - 1 {
			g.write(', ')
		}
	}
	g.write('}))')
	if g.is_shared {
		g.write(', .mtx = sync__new_rwmutex()}')
		if is_amp {
			g.write(', sizeof($shared_styp))')
		}
	} else if is_amp {
		g.write(', sizeof($styp))')
	}
}

// `ui.foo(button)` =>
// `ui__foo(I_ui__Button_to_ui__Widget(` ...
fn (mut g Gen) interface_call(typ, interface_type table.Type) {
	interface_styp := g.cc_type(interface_type)
	styp := g.cc_type(typ)
	mut cast_fn_name := 'I_${styp}_to_Interface_$interface_styp'
	if interface_type.is_ptr() {
		cast_fn_name += '_ptr'
	}
	g.write('${cast_fn_name}(')
	if !typ.is_ptr() {
		g.write('&')
	}
}

fn (mut g Gen) panic_debug_info(pos token.Position) (int, string, string, string) {
	paline := pos.line_nr + 1
	pafile := g.fn_decl.file.replace('\\', '/')
	pafn := g.fn_decl.name.after('.')
	pamod := g.fn_decl.modname()
	return paline, pafile, pamod, pafn
}
