module CxxInterface

################################################################################

clean_code(expr) = expr
function clean_code(expr::Expr)
    expr = Expr(expr.head, map(clean_code, filter(arg -> !(arg isa LineNumberNode), expr.args))...)
    if expr.head ≡ :block && length(expr.args) == 1
        expr = expr.args[1]::Expr
    end
    if expr.head ≡ :call && length(expr.args) ≥ 2 && expr.args[1] ≡ :ccall
        arg1 = expr.args[2]
        if arg1 isa Expr && arg1.head ≡ :tuple && length(arg1.args) ≥ 2
            arg2 = arg1.args[2]
            if arg2 isa String
                arg1.args[2] = splitpath(arg2)[end]
            end
        end
    end
    return expr
end

"Julia identifier"
const JuliaName = Union{Expr,Symbol}
export JuliaName

"C++ identifier"
const CxxName = AbstractString
export CxxName

"C++ type"
const CxxType = AbstractString
export CxxType

function cxxname(str::AbstractString)
    return String([cxxname(ch) for ch in str])
end
function cxxname(ch::Char)
    if Base.Unicode.isletter(ch) || Base.Unicode.isdigit(ch) || ch == '_'
        return ch
    else
        return '_'
    end
end
export cxxname

# Julia's complex numbers need to be mapped to C complex numbers, not
# C++ complex numbers, because C and C++ behave differently under
# certain circumstances (e.g. when returned from a function on a
# 32-bit Intel system).
const cxxtype = Dict{Type,CxxType}(Bool => "uint8_t", Int8 => "int8_t", Int16 => "int16_t", Int32 => "int32_t", Int64 => "int64_t",
                                   UInt8 => "uint8_t", UInt16 => "uint16_t", UInt32 => "uint32_t", UInt64 => "uint64_t",
                                   Float32 => "float", Float64 => "double", Complex{Float32} => "float _Complex",
                                   Complex{Float64} => "double _Complex", Ptr{Cvoid} => "void *")
export cxxtype

################################################################################

const initialized_modules = Set{Symbol}()

function cxxprelude(filename::AbstractString, cxx_stmts::AbstractString)
    cxx_code = """
               #include <ccomplex>
               #include <cstdint>

               $cxx_stmts
               """
    quote
        if nameof(@__MODULE__) ∉ CxxInterface.initialized_modules
            push!(CxxInterface.initialized_modules, nameof(@__MODULE__))

            const cxx_filename = Ref{AbstractString}("code.cxx")
            function set_cxx_filename!(filename::AbstractString)
                return cxx_filename[] = filename
            end

            const cxx_chunks = Dict{AbstractString,Vector{String}}()
            function cxx_add_code!(cxx_code::AbstractString)
                return push!(get!(cxx_chunks, cxx_filename[], String[]), cxx_code)
            end
            function cxx_get_code()
                iobuffer = IOBuffer()
                allcode = Dict{AbstractString,String}()
                for (filename, chunks) in cxx_chunks
                    for chunk in chunks
                        println(iobuffer, chunk)
                    end
                    allcode[filename] = String(take!(iobuffer))
                end
                return allcode
            end
            function cxx_write_code!()
                println("Generating C++ code:")
                allcode = cxx_get_code()
                for (filename, content) in allcode
                    println("Generating $filename...")
                    write(filename, content)
                end
                println("Done.")
                return nothing
            end
        end

        set_cxx_filename!($filename)
        cxx_add_code!($cxx_code)
    end
end
export cxxprelude

function cxxcode(cxx_stmts::AbstractString)
    cxx_code = """
               $cxx_stmts
               """
    quote
        cxx_add_code!($cxx_code)
    end
end
export cxxcode

struct FnName
    julia_name::JuliaName
    cxx_name::CxxName
    cxx_library::Union{CxxName,Ptr}
end
export FnName

struct FnResult
    julia_type::Type
    cxx_type::CxxType
    final_julia_type::Type
    convert_to_final::Any
end
export FnResult
FnResult(julia_type::Type, cxx_type::CxxType) = FnResult(julia_type, cxx_type, julia_type, identity)

struct FnArg
    julia_name::JuliaName
    julia_type::Type
    cxx_name::CxxName
    cxx_type::CxxType
    initial_julia_type::Type
    convert_from_initial::Any
    skip::Bool
    function FnArg(julia_name::JuliaName, julia_type::Type, cxx_name::CxxName, cxx_type::CxxType, initial_julia_type::Type,
                   convert_from_initial::Any; skip::Bool=false)
        return new(julia_name, julia_type, cxx_name, cxx_type, initial_julia_type, convert_from_initial, skip)
    end
end
export FnArg
function FnArg(julia_name::JuliaName, julia_type::Type, cxx_name::CxxName, cxx_type::CxxType; skip::Bool=false)
    return FnArg(julia_name, julia_type, cxx_name, cxx_type, julia_type, identity; skip=skip)
end

const VarName = FnName
export VarName
const VarType = FnResult
export VarType

function cxxvariable(name::VarName, type::VarType, cxx_stmts::AbstractString)
    julia_code = quote
        const $(name.julia_name) = begin
            res = unsafe_load(cglobal(($(name.cxx_name), $(name.cxx_library)), $(type.julia_type)))
            $(type.convert_to_final(:res))::$(type.final_julia_type)
        end
    end
    julia_code = clean_code(julia_code)

    cxx_code = """
        /*
        $(string(julia_code))
        */
        extern "C" const $(type.cxx_type) $(name.cxx_name) = [] { $cxx_stmts }();
        """
    quote
        cxx_add_code!($cxx_code)
        $julia_code
    end
end
export cxxvariable

function cxxfunction(name::FnName, result::FnResult, arguments::AbstractVector{FnArg}, cxx_stmts::AbstractString)
    julia_code = quote
        function $(name.julia_name)($([:($(arg.julia_name)::$(arg.initial_julia_type)) for arg in arguments]...))
            res = ccall(($(name.cxx_name), $(name.cxx_library)), $(result.julia_type),
                        ($([arg.julia_type for arg in arguments if !arg.skip]...),),
                        $([arg.convert_from_initial(arg.julia_name) for arg in arguments if !arg.skip]...))
            return $(result.convert_to_final(:res))::$(result.final_julia_type)
        end
    end
    julia_code = clean_code(julia_code)

    cxx_code = """
        /*
        $(string(julia_code))
        */
        extern "C" $(result.cxx_type) $(name.cxx_name)(
            $(join(["$(arg.cxx_type) $(arg.cxx_name)" for arg in arguments if !arg.skip], ",\n    "))
        ) {
            $cxx_stmts
        }
        """
    quote
        cxx_add_code!($cxx_code)
        $julia_code
    end
end
export cxxfunction

end
