''' Helper functions and data for C++ and Erlang files generation
'''

exclude = {"malfunction",
           "table",
           "service",
           "subscriber",
           "test"
}

types = {
     "atom()": "std::string",
     "any()": "ETERM*",
     "map()": "ETERM*",
     "string()": "std::string",
     "binary()": "ETERM*",
     "integer()": "int64_t",
     "pos_integer()": "uint64_t",
     "float()": "double",

     ## USER DEFINED TYPES
     "credential_id()": "std::string",
     "remote_id()": "std::string",
     "account_id()": "std::string",
     "session_id()": "std::string",
     "user_id()": "std::string",
     "grid_id()": "std::string",
     "cluster_id()": "std::string",
     "partition_id()": "std::string",
     "node_id()": "std::string",
     "job_id()": "std::string",
     "image_id()": "std::string",
     "relocation_id()": "std::uint64_t",
     "hook_id()": "std::string"
}

type_suffix = {
     "atom()": "atom",
     "any()": "eterm",
     "map()": "eterm",
     "string()": "str",
     "binary()": "eterm",
     "integer()": "int64_t",
     "pos_integer()": "uint64_t",
     "float()": "double",

     ## USER DEFINED TYPES SUFFIX
     "credential_id()": "str",
     "remote_id()": "str",
     "account_id()": "str",
     "session_id()": "str",
     "user_id()": "str",
     "grid_id()": "str",
     "cluster_id()": "str",
     "partition_id()": "str",
     "node_id()": "str",
     "job_id()": "str",
     "image_id()": "str",
     "relocation_id()": "uint64_t",
     "hook_id()": "str"
}

printer = {
     "atom()": "%s",
     "any()": "eterm",
     "map()": "eterm",
     "binary()": "eterm",
     "string()": "%s",
     "integer()": "%ld",
     "pos_integer()": "%ld",
     "float()": "%f",

     ## USER DEFINED PRINTERS
     "credential_id()": "%s",
     "remote_id()": "%s",
     "account_id()": "%s",
     "session_id()": "%s",
     "user_id()": "%s",
     "grid_id()": "%s",
     "cluster_id()": "%s",
     "partition_id()": "%s",
     "node_id()": "%s",
     "job_id()": "%s",
     "image_id()": "%s",
     "relocation_id()": "%ld",
     "hook_id()": "%s"
}


def struct_param_type(r):
    is_struct = False
    if '#' in r:
        if r.startswith('#'):
            r = r[1:]
        r = r.replace('{}', '')
        is_struct = True
    return ('Swm' + r.title(), r, is_struct)


def get_tuple_type(pp):
    tuple_type = ''
    for tp in pp:
        tp = tp.strip()
        if tp == "atom()":
            tuple_type += '_atom'
        elif tp == "string()":
            tuple_type += '_str'
        elif tp == "any()":
            tuple_type += '_eterm'
    return tuple_type


def c_struct(pp):
    s = 'SwmTuple'
    for p in pp:
        p = p.strip()
        if p in type_suffix.keys():
            p = type_suffix[p]
        if len(p)>1:
            s += p.title()
    return s
