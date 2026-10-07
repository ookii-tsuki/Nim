// N# semantic conformance oracle - the Roslyn half.
//
// Reads one or more `.ns` files as C# (every `.ns` test is deliberately valid
// C#, which nsharp/tests/run_cs.sh already relies on), asks Roslyn to resolve
// them, and prints the same projected facts the N# frontend prints from
// compiler/nsharp/tools/dumpsema.nim. nsharp/tests/run_sema.sh diffs the two.
//
// Nothing here is N#-specific: this is the plain C# meaning of the program, the
// truth the frontend is measured against. What is projected is deliberately
// narrow (see nsharp/CONFORMANCE.md) so that it can be exact:
//
//   using <ns>                     each `using` directive
//   member <recv>.<name> = <ns> | <ret>
//                                  an *instance* member access on a receiver of a
//                                  library (non-source) type, the namespace of the
//                                  declaring type and the result class.
//
// A receiver is spelled the way the frontend spells it: a C# keyword for a
// built-in, `array` for an array, otherwise the type's short name. A result is
// one of the shared tokens (void/int/float/bool/char/string); anything else is
// `other` and is not projected at all. Both blocks are sorted, so the output is
// independent of the order the tree is walked in.

using System;
using System.Collections.Generic;
using System.IO;
using System.Linq;
using Microsoft.CodeAnalysis;
using Microsoft.CodeAnalysis.CSharp;
using Microsoft.CodeAnalysis.CSharp.Syntax;

static class Program
{
    static int Main(string[] args)
    {
        if (args.Length < 1)
        {
            Console.Error.WriteLine("usage: nsoracle <main.ns> [module.ns ...]");
            return 2;
        }

        // Every file is compiled together, but facts are read from the main file
        // alone -- the same file the N# tool dumps. A sibling is a dependency
        // (`class Math { ... }`), and its own members belong to no projection.
        var trees = new List<SyntaxTree>();
        foreach (var arg in args)
        {
            var path = Path.GetFullPath(arg);
            string text;
            try
            {
                text = File.ReadAllText(path);
            }
            catch (IOException e)
            {
                Console.Error.WriteLine("nsoracle: " + e.Message);
                return 2;
            }
            trees.Add(CSharpSyntaxTree.ParseText(text, path: path));
        }

        // The reference set is the assemblies the running SDK trusts, so the BCL
        // the program is compiled against is the one the tool itself runs on.
        var refs = new List<MetadataReference>();
        var tpa = (string)AppContext.GetData("TRUSTED_PLATFORM_ASSEMBLIES");
        if (tpa != null)
        {
            foreach (var p in tpa.Split(Path.PathSeparator))
            {
                if (p.Length > 0)
                {
                    refs.Add(MetadataReference.CreateFromFile(p));
                }
            }
        }

        var compilation = CSharpCompilation.Create(
            "nsoracle", trees, refs,
            new CSharpCompilationOptions(OutputKind.DynamicallyLinkedLibrary));

        var main = trees[0];
        var model = compilation.GetSemanticModel(main);
        var root = main.GetRoot();

        var usings = new List<string>();
        var facts = new List<string>();

        foreach (var u in root.DescendantNodes().OfType<UsingDirectiveSyntax>())
        {
            if (u.Name == null || u.StaticKeyword.RawKind != 0)
            {
                continue;
            }
            usings.Add(u.Alias != null
                ? "using " + u.Alias.Name + " = " + u.Name
                : "using " + u.Name);
        }

        foreach (var ma in root.DescendantNodes().OfType<MemberAccessExpressionSyntax>())
        {
            var sym = model.GetSymbolInfo(ma).Symbol;
            if (sym == null)
            {
                continue;
            }

            // Instance members of library types only. A static access
            // (`Console.WriteLine`, `String.Concat`) names no member through the
            // prelude and is out of this stage's scope; a member the program
            // itself declares is the program's own business.
            if (sym.IsStatic)
            {
                continue;
            }
            if (!(sym is IMethodSymbol || sym is IPropertySymbol || sym is IFieldSymbol))
            {
                continue;
            }
            if (!sym.DeclaringSyntaxReferences.IsEmpty)
            {
                continue;
            }

            var recv = RecvName(model.GetTypeInfo(ma.Expression).Type);
            if (recv.Length == 0)
            {
                continue;
            }

            var ns = sym.ContainingType?.ContainingNamespace?.ToDisplayString();
            if (string.IsNullOrEmpty(ns) || ns == "<global namespace>")
            {
                continue;
            }

            // A declaration whose own result is a type parameter (`Queue<T>
            // .Dequeue`'s `T`) does not name its class on its own, and the N#
            // side cannot either, so neither side projects it.
            var orig = sym.OriginalDefinition;
            var oret = orig is IMethodSymbol om ? om.ReturnType
                     : orig is IPropertySymbol op ? op.Type
                     : ((IFieldSymbol)orig).Type;
            if (HasTypeParameter(oret))
            {
                continue;
            }

            var isVoid = sym is IMethodSymbol mth && mth.ReturnsVoid;
            var ret = sym is IMethodSymbol m2 ? m2.ReturnType
                    : sym is IPropertySymbol pr ? pr.Type
                    : ((IFieldSymbol)sym).Type;
            var token = RetToken(ret, isVoid);
            if (!Projected(token))
            {
                continue;
            }

            facts.Add("member " + recv + "." + ma.Name.Identifier.ValueText +
                      " = " + ns + " | " + token);
        }

        usings.Sort(StringComparer.Ordinal);
        facts.Sort(StringComparer.Ordinal);
        foreach (var u in usings)
        {
            Console.Out.WriteLine(u);
        }
        foreach (var f in facts)
        {
            Console.Out.WriteLine(f);
        }
        return 0;
    }

    // The receiver spelled the way the N# frontend spells it: the C# keyword of a
    // built-in type (so `System.Int64` reads `long`, as the frontend's own
    // vocabulary does), `array` for an array, otherwise the short type name.
    static string RecvName(ITypeSymbol t)
    {
        if (t == null)
        {
            return "";
        }
        if (t is IArrayTypeSymbol)
        {
            return "array";
        }
        // A `T?` is not projected: the N# frontend lowers it to an `Option`
        // whose members live in its intrinsics, not in `System.Nullable`.
        if (t.OriginalDefinition.SpecialType == SpecialType.System_Nullable_T)
        {
            return "";
        }
        switch (t.SpecialType)
        {
            case SpecialType.System_Boolean: return "bool";
            case SpecialType.System_Char: return "char";
            case SpecialType.System_String: return "string";
            case SpecialType.System_Object: return "object";
            case SpecialType.System_SByte: return "sbyte";
            case SpecialType.System_Byte: return "byte";
            case SpecialType.System_Int16: return "short";
            case SpecialType.System_UInt16: return "ushort";
            case SpecialType.System_Int32: return "int";
            case SpecialType.System_UInt32: return "uint";
            case SpecialType.System_Int64: return "long";
            case SpecialType.System_UInt64: return "ulong";
            case SpecialType.System_Single: return "float";
            case SpecialType.System_Double: return "double";
            case SpecialType.System_IntPtr: return "nint";
            case SpecialType.System_UIntPtr: return "nuint";
            default: return t.Name;
        }
    }

    // The shared result token. Deliberately coarse on the numeric axis (every
    // integer is `int`) but exact on the axis that matters: the difference
    // between a value, a string, a sequence and an object. Everything the stage
    // does not project is `other`.
    static string RetToken(ITypeSymbol t, bool isVoid)
    {
        if (isVoid)
        {
            return "void";
        }
        if (t == null)
        {
            return "other";
        }
        switch (t.SpecialType)
        {
            case SpecialType.System_Boolean: return "bool";
            case SpecialType.System_Char: return "char";
            case SpecialType.System_String: return "string";
            case SpecialType.System_SByte:
            case SpecialType.System_Byte:
            case SpecialType.System_Int16:
            case SpecialType.System_UInt16:
            case SpecialType.System_Int32:
            case SpecialType.System_UInt32:
            case SpecialType.System_Int64:
            case SpecialType.System_UInt64:
            case SpecialType.System_IntPtr:
            case SpecialType.System_UIntPtr: return "int";
            case SpecialType.System_Single:
            case SpecialType.System_Double: return "float";
            default: return "other";
        }
    }

    static bool Projected(string token)
    {
        return token == "void" || token == "int" || token == "float" ||
               token == "bool" || token == "char" || token == "string";
    }

    // True when a type is, or is built from, a type parameter -- the unsubstituted
    // shape of `T`, `T[]` or `KeyValuePair<K, V>`.
    static bool HasTypeParameter(ITypeSymbol t)
    {
        if (t == null)
        {
            return false;
        }
        if (t is ITypeParameterSymbol)
        {
            return true;
        }
        if (t is IArrayTypeSymbol a)
        {
            return HasTypeParameter(a.ElementType);
        }
        if (t is IPointerTypeSymbol p)
        {
            return HasTypeParameter(p.PointedAtType);
        }
        if (t is INamedTypeSymbol n)
        {
            return n.TypeArguments.Any(HasTypeParameter);
        }
        return false;
    }
}
