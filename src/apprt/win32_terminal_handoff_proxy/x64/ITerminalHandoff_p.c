

/* this ALWAYS GENERATED file contains the proxy stub code */


 /* File created by MIDL compiler version 8.01.0628 */
/* at Mon Jan 18 22:14:07 2038
 */
/* Compiler settings for C:\Users\amant\.t3\worktrees\winghostty\wt-issues-b2-handoff\src\apprt\win32_terminal_handoff_proxy\ITerminalHandoff.idl:
    Oicf, W1, Zp8, env=Win64 (32b run), target_arch=AMD64 8.01.0628 
    protocol : all , ms_ext, c_ext, robust
    error checks: allocation ref bounds_check enum stub_data 
    VC __declspec() decoration level: 
         __declspec(uuid()), __declspec(selectany), __declspec(novtable)
         DECLSPEC_UUID(), MIDL_INTERFACE()
*/
/* @@MIDL_FILE_HEADING(  ) */

#if defined(_M_AMD64)


#if _MSC_VER >= 1200
#pragma warning(push)
#endif

#pragma warning( disable: 4211 )  /* redefine extern to static */
#pragma warning( disable: 4232 )  /* dllimport identity*/
#pragma warning( disable: 4024 )  /* array to pointer mapping*/
#pragma warning( disable: 4152 )  /* function/data pointer conversion in expression */

#define USE_STUBLESS_PROXY


/* verify that the <rpcproxy.h> version is high enough to compile this file*/
#ifndef __REDQ_RPCPROXY_H_VERSION__
#define __REQUIRED_RPCPROXY_H_VERSION__ 475
#endif


#include "rpcproxy.h"
#include "ndr64types.h"
#ifndef __RPCPROXY_H_VERSION__
#error this stub requires an updated version of <rpcproxy.h>
#endif /* __RPCPROXY_H_VERSION__ */


#include "ITerminalHandoff.h"

#define TYPE_FORMAT_STRING_SIZE   93                                
#define PROC_FORMAT_STRING_SIZE   217                               
#define EXPR_FORMAT_STRING_SIZE   1                                 
#define TRANSMIT_AS_TABLE_SIZE    0            
#define WIRE_MARSHAL_TABLE_SIZE   1            

typedef struct _ITerminalHandoff_MIDL_TYPE_FORMAT_STRING
    {
    short          Pad;
    unsigned char  Format[ TYPE_FORMAT_STRING_SIZE ];
    } ITerminalHandoff_MIDL_TYPE_FORMAT_STRING;

typedef struct _ITerminalHandoff_MIDL_PROC_FORMAT_STRING
    {
    short          Pad;
    unsigned char  Format[ PROC_FORMAT_STRING_SIZE ];
    } ITerminalHandoff_MIDL_PROC_FORMAT_STRING;

typedef struct _ITerminalHandoff_MIDL_EXPR_FORMAT_STRING
    {
    long          Pad;
    unsigned char  Format[ EXPR_FORMAT_STRING_SIZE ];
    } ITerminalHandoff_MIDL_EXPR_FORMAT_STRING;


static const RPC_SYNTAX_IDENTIFIER  _RpcTransferSyntax_2_0 = 
{{0x8A885D04,0x1CEB,0x11C9,{0x9F,0xE8,0x08,0x00,0x2B,0x10,0x48,0x60}},{2,0}};

static const RPC_SYNTAX_IDENTIFIER  _NDR64_RpcTransferSyntax_1_0 = 
{{0x71710533,0xbeba,0x4937,{0x83,0x19,0xb5,0xdb,0xef,0x9c,0xcc,0x36}},{1,0}};

#if defined(_CONTROL_FLOW_GUARD_XFG)
#define XFG_TRAMPOLINES(ObjectType)\
NDR_SHAREABLE unsigned long ObjectType ## _UserSize_XFG(unsigned long * pFlags, unsigned long Offset, void * pObject)\
{\
return  ObjectType ## _UserSize(pFlags, Offset, (ObjectType *)pObject);\
}\
NDR_SHAREABLE unsigned char * ObjectType ## _UserMarshal_XFG(unsigned long * pFlags, unsigned char * pBuffer, void * pObject)\
{\
return ObjectType ## _UserMarshal(pFlags, pBuffer, (ObjectType *)pObject);\
}\
NDR_SHAREABLE unsigned char * ObjectType ## _UserUnmarshal_XFG(unsigned long * pFlags, unsigned char * pBuffer, void * pObject)\
{\
return ObjectType ## _UserUnmarshal(pFlags, pBuffer, (ObjectType *)pObject);\
}\
NDR_SHAREABLE void ObjectType ## _UserFree_XFG(unsigned long * pFlags, void * pObject)\
{\
ObjectType ## _UserFree(pFlags, (ObjectType *)pObject);\
}
#define XFG_TRAMPOLINES64(ObjectType)\
NDR_SHAREABLE unsigned long ObjectType ## _UserSize64_XFG(unsigned long * pFlags, unsigned long Offset, void * pObject)\
{\
return  ObjectType ## _UserSize64(pFlags, Offset, (ObjectType *)pObject);\
}\
NDR_SHAREABLE unsigned char * ObjectType ## _UserMarshal64_XFG(unsigned long * pFlags, unsigned char * pBuffer, void * pObject)\
{\
return ObjectType ## _UserMarshal64(pFlags, pBuffer, (ObjectType *)pObject);\
}\
NDR_SHAREABLE unsigned char * ObjectType ## _UserUnmarshal64_XFG(unsigned long * pFlags, unsigned char * pBuffer, void * pObject)\
{\
return ObjectType ## _UserUnmarshal64(pFlags, pBuffer, (ObjectType *)pObject);\
}\
NDR_SHAREABLE void ObjectType ## _UserFree64_XFG(unsigned long * pFlags, void * pObject)\
{\
ObjectType ## _UserFree64(pFlags, (ObjectType *)pObject);\
}
#define XFG_BIND_TRAMPOLINES(HandleType, ObjectType)\
static void* ObjectType ## _bind_XFG(HandleType pObject)\
{\
return ObjectType ## _bind((ObjectType) pObject);\
}\
static void ObjectType ## _unbind_XFG(HandleType pObject, handle_t ServerHandle)\
{\
ObjectType ## _unbind((ObjectType) pObject, ServerHandle);\
}
#define XFG_TRAMPOLINE_FPTR(Function) Function ## _XFG
#define XFG_TRAMPOLINE_FPTR_DEPENDENT_SYMBOL(Symbol) Symbol ## _XFG
#else
#define XFG_TRAMPOLINES(ObjectType)
#define XFG_TRAMPOLINES64(ObjectType)
#define XFG_BIND_TRAMPOLINES(HandleType, ObjectType)
#define XFG_TRAMPOLINE_FPTR(Function) Function
#define XFG_TRAMPOLINE_FPTR_DEPENDENT_SYMBOL(Symbol) Symbol
#endif



extern const ITerminalHandoff_MIDL_TYPE_FORMAT_STRING ITerminalHandoff__MIDL_TypeFormatString;
extern const ITerminalHandoff_MIDL_PROC_FORMAT_STRING ITerminalHandoff__MIDL_ProcFormatString;
extern const ITerminalHandoff_MIDL_EXPR_FORMAT_STRING ITerminalHandoff__MIDL_ExprFormatString;

#ifdef __cplusplus
namespace {
#endif

extern const MIDL_STUB_DESC Object_StubDesc;
#ifdef __cplusplus
}
#endif


extern const MIDL_SERVER_INFO ITerminalHandoff_ServerInfo;
extern const MIDL_STUBLESS_PROXY_INFO ITerminalHandoff_ProxyInfo;

#ifdef __cplusplus
namespace {
#endif

extern const MIDL_STUB_DESC Object_StubDesc;
#ifdef __cplusplus
}
#endif


extern const MIDL_SERVER_INFO ITerminalHandoff2_ServerInfo;
extern const MIDL_STUBLESS_PROXY_INFO ITerminalHandoff2_ProxyInfo;

#ifdef __cplusplus
namespace {
#endif

extern const MIDL_STUB_DESC Object_StubDesc;
#ifdef __cplusplus
}
#endif


extern const MIDL_SERVER_INFO ITerminalHandoff3_ServerInfo;
extern const MIDL_STUBLESS_PROXY_INFO ITerminalHandoff3_ProxyInfo;


extern const USER_MARSHAL_ROUTINE_QUADRUPLE NDR64_UserMarshalRoutines[ WIRE_MARSHAL_TABLE_SIZE ];extern const USER_MARSHAL_ROUTINE_QUADRUPLE UserMarshalRoutines[ WIRE_MARSHAL_TABLE_SIZE ];

#if !defined(__RPC_WIN64__)
#error  Invalid build platform for this stub.
#endif

static const ITerminalHandoff_MIDL_PROC_FORMAT_STRING ITerminalHandoff__MIDL_ProcFormatString =
    {
        0,
        {

	/* Procedure EstablishPtyHandoff */

			0x33,		/* FC_AUTO_HANDLE */
			0x6c,		/* Old Flags:  object, Oi2 */
/*  2 */	NdrFcLong( 0x0 ),	/* 0 */
/*  6 */	NdrFcShort( 0x3 ),	/* 3 */
/*  8 */	NdrFcShort( 0x40 ),	/* X64 Stack size/offset = 64 */
/* 10 */	NdrFcShort( 0x0 ),	/* 0 */
/* 12 */	NdrFcShort( 0x8 ),	/* 8 */
/* 14 */	0x46,		/* Oi2 Flags:  clt must size, has return, has ext, */
			0x7,		/* 7 */
/* 16 */	0xa,		/* 10 */
			0x1,		/* Ext Flags:  new corr desc, */
/* 18 */	NdrFcShort( 0x0 ),	/* 0 */
/* 20 */	NdrFcShort( 0x0 ),	/* 0 */
/* 22 */	NdrFcShort( 0x0 ),	/* 0 */
/* 24 */	NdrFcShort( 0x0 ),	/* 0 */

	/* Parameter in */

/* 26 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 28 */	NdrFcShort( 0x8 ),	/* X64 Stack size/offset = 8 */
/* 30 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter out */

/* 32 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 34 */	NdrFcShort( 0x10 ),	/* X64 Stack size/offset = 16 */
/* 36 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter signal */

/* 38 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 40 */	NdrFcShort( 0x18 ),	/* X64 Stack size/offset = 24 */
/* 42 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter ref */

/* 44 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 46 */	NdrFcShort( 0x20 ),	/* X64 Stack size/offset = 32 */
/* 48 */	NdrFcShort( 0x8 ),	/* Type Offset=8 */

	/* Parameter server */

/* 50 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 52 */	NdrFcShort( 0x28 ),	/* X64 Stack size/offset = 40 */
/* 54 */	NdrFcShort( 0xe ),	/* Type Offset=14 */

	/* Parameter client */

/* 56 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 58 */	NdrFcShort( 0x30 ),	/* X64 Stack size/offset = 48 */
/* 60 */	NdrFcShort( 0xe ),	/* Type Offset=14 */

	/* Return value */

/* 62 */	NdrFcShort( 0x70 ),	/* Flags:  out, return, base type, */
/* 64 */	NdrFcShort( 0x38 ),	/* X64 Stack size/offset = 56 */
/* 66 */	0x8,		/* FC_LONG */
			0x0,		/* 0 */

	/* Procedure EstablishPtyHandoff */

/* 68 */	0x33,		/* FC_AUTO_HANDLE */
			0x6c,		/* Old Flags:  object, Oi2 */
/* 70 */	NdrFcLong( 0x0 ),	/* 0 */
/* 74 */	NdrFcShort( 0x3 ),	/* 3 */
/* 76 */	NdrFcShort( 0x48 ),	/* X64 Stack size/offset = 72 */
/* 78 */	NdrFcShort( 0x0 ),	/* 0 */
/* 80 */	NdrFcShort( 0x8 ),	/* 8 */
/* 82 */	0x46,		/* Oi2 Flags:  clt must size, has return, has ext, */
			0x8,		/* 8 */
/* 84 */	0xa,		/* 10 */
			0x85,		/* Ext Flags:  new corr desc, srv corr check, has big byval param */
/* 86 */	NdrFcShort( 0x0 ),	/* 0 */
/* 88 */	NdrFcShort( 0x1 ),	/* 1 */
/* 90 */	NdrFcShort( 0x0 ),	/* 0 */
/* 92 */	NdrFcShort( 0x0 ),	/* 0 */

	/* Parameter in */

/* 94 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 96 */	NdrFcShort( 0x8 ),	/* X64 Stack size/offset = 8 */
/* 98 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter out */

/* 100 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 102 */	NdrFcShort( 0x10 ),	/* X64 Stack size/offset = 16 */
/* 104 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter signal */

/* 106 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 108 */	NdrFcShort( 0x18 ),	/* X64 Stack size/offset = 24 */
/* 110 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter ref */

/* 112 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 114 */	NdrFcShort( 0x20 ),	/* X64 Stack size/offset = 32 */
/* 116 */	NdrFcShort( 0x8 ),	/* Type Offset=8 */

	/* Parameter server */

/* 118 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 120 */	NdrFcShort( 0x28 ),	/* X64 Stack size/offset = 40 */
/* 122 */	NdrFcShort( 0xe ),	/* Type Offset=14 */

	/* Parameter client */

/* 124 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 126 */	NdrFcShort( 0x30 ),	/* X64 Stack size/offset = 48 */
/* 128 */	NdrFcShort( 0xe ),	/* Type Offset=14 */

	/* Parameter startupInfo */

/* 130 */	NdrFcShort( 0x10b ),	/* Flags:  must size, must free, in, simple ref, */
/* 132 */	NdrFcShort( 0x38 ),	/* X64 Stack size/offset = 56 */
/* 134 */	NdrFcShort( 0x3c ),	/* Type Offset=60 */

	/* Return value */

/* 136 */	NdrFcShort( 0x70 ),	/* Flags:  out, return, base type, */
/* 138 */	NdrFcShort( 0x40 ),	/* X64 Stack size/offset = 64 */
/* 140 */	0x8,		/* FC_LONG */
			0x0,		/* 0 */

	/* Procedure EstablishPtyHandoff */

/* 142 */	0x33,		/* FC_AUTO_HANDLE */
			0x6c,		/* Old Flags:  object, Oi2 */
/* 144 */	NdrFcLong( 0x0 ),	/* 0 */
/* 148 */	NdrFcShort( 0x3 ),	/* 3 */
/* 150 */	NdrFcShort( 0x48 ),	/* X64 Stack size/offset = 72 */
/* 152 */	NdrFcShort( 0x0 ),	/* 0 */
/* 154 */	NdrFcShort( 0x8 ),	/* 8 */
/* 156 */	0x47,		/* Oi2 Flags:  srv must size, clt must size, has return, has ext, */
			0x8,		/* 8 */
/* 158 */	0xa,		/* 10 */
			0x5,		/* Ext Flags:  new corr desc, srv corr check, */
/* 160 */	NdrFcShort( 0x0 ),	/* 0 */
/* 162 */	NdrFcShort( 0x1 ),	/* 1 */
/* 164 */	NdrFcShort( 0x0 ),	/* 0 */
/* 166 */	NdrFcShort( 0x0 ),	/* 0 */

	/* Parameter in */

/* 168 */	NdrFcShort( 0x2113 ),	/* Flags:  must size, must free, out, simple ref, srv alloc size=8 */
/* 170 */	NdrFcShort( 0x8 ),	/* X64 Stack size/offset = 8 */
/* 172 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter out */

/* 174 */	NdrFcShort( 0x2113 ),	/* Flags:  must size, must free, out, simple ref, srv alloc size=8 */
/* 176 */	NdrFcShort( 0x10 ),	/* X64 Stack size/offset = 16 */
/* 178 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter signal */

/* 180 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 182 */	NdrFcShort( 0x18 ),	/* X64 Stack size/offset = 24 */
/* 184 */	NdrFcShort( 0x2 ),	/* Type Offset=2 */

	/* Parameter reference */

/* 186 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 188 */	NdrFcShort( 0x20 ),	/* X64 Stack size/offset = 32 */
/* 190 */	NdrFcShort( 0x8 ),	/* Type Offset=8 */

	/* Parameter server */

/* 192 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 194 */	NdrFcShort( 0x28 ),	/* X64 Stack size/offset = 40 */
/* 196 */	NdrFcShort( 0xe ),	/* Type Offset=14 */

	/* Parameter client */

/* 198 */	NdrFcShort( 0x8b ),	/* Flags:  must size, must free, in, by val, */
/* 200 */	NdrFcShort( 0x30 ),	/* X64 Stack size/offset = 48 */
/* 202 */	NdrFcShort( 0xe ),	/* Type Offset=14 */

	/* Parameter startupInfo */

/* 204 */	NdrFcShort( 0x10b ),	/* Flags:  must size, must free, in, simple ref, */
/* 206 */	NdrFcShort( 0x38 ),	/* X64 Stack size/offset = 56 */
/* 208 */	NdrFcShort( 0x3c ),	/* Type Offset=60 */

	/* Return value */

/* 210 */	NdrFcShort( 0x70 ),	/* Flags:  out, return, base type, */
/* 212 */	NdrFcShort( 0x40 ),	/* X64 Stack size/offset = 64 */
/* 214 */	0x8,		/* FC_LONG */
			0x0,		/* 0 */

			0x0
        }
    };

static const ITerminalHandoff_MIDL_TYPE_FORMAT_STRING ITerminalHandoff__MIDL_TypeFormatString =
    {
        0,
        {
			NdrFcShort( 0x0 ),	/* 0 */
/*  2 */	0x3c,		/* FC_SYSTEM_HANDLE */
			0xc,		/* 12 */
/*  4 */	NdrFcLong( 0x0 ),	/* 0 */
/*  8 */	0x3c,		/* FC_SYSTEM_HANDLE */
			0x0,		/* 0 */
/* 10 */	NdrFcLong( 0x0 ),	/* 0 */
/* 14 */	0x3c,		/* FC_SYSTEM_HANDLE */
			0x4,		/* 4 */
/* 16 */	NdrFcLong( 0x0 ),	/* 0 */
/* 20 */	
			0x11, 0x0,	/* FC_RP */
/* 22 */	NdrFcShort( 0x26 ),	/* Offset= 38 (60) */
/* 24 */	
			0x12, 0x0,	/* FC_UP */
/* 26 */	NdrFcShort( 0xe ),	/* Offset= 14 (40) */
/* 28 */	
			0x1b,		/* FC_CARRAY */
			0x1,		/* 1 */
/* 30 */	NdrFcShort( 0x2 ),	/* 2 */
/* 32 */	0x9,		/* Corr desc: FC_ULONG */
			0x0,		/*  */
/* 34 */	NdrFcShort( 0xfffc ),	/* -4 */
/* 36 */	NdrFcShort( 0x1 ),	/* Corr flags:  early, */
/* 38 */	0x6,		/* FC_SHORT */
			0x5b,		/* FC_END */
/* 40 */	
			0x17,		/* FC_CSTRUCT */
			0x3,		/* 3 */
/* 42 */	NdrFcShort( 0x8 ),	/* 8 */
/* 44 */	NdrFcShort( 0xfff0 ),	/* Offset= -16 (28) */
/* 46 */	0x8,		/* FC_LONG */
			0x8,		/* FC_LONG */
/* 48 */	0x5c,		/* FC_PAD */
			0x5b,		/* FC_END */
/* 50 */	0xb4,		/* FC_USER_MARSHAL */
			0x83,		/* 131 */
/* 52 */	NdrFcShort( 0x0 ),	/* 0 */
/* 54 */	NdrFcShort( 0x8 ),	/* 8 */
/* 56 */	NdrFcShort( 0x0 ),	/* 0 */
/* 58 */	NdrFcShort( 0xffde ),	/* Offset= -34 (24) */
/* 60 */	
			0x1a,		/* FC_BOGUS_STRUCT */
			0x3,		/* 3 */
/* 62 */	NdrFcShort( 0x38 ),	/* 56 */
/* 64 */	NdrFcShort( 0x0 ),	/* 0 */
/* 66 */	NdrFcShort( 0x0 ),	/* Offset= 0 (66) */
/* 68 */	0x4c,		/* FC_EMBEDDED_COMPLEX */
			0x0,		/* 0 */
/* 70 */	NdrFcShort( 0xffec ),	/* Offset= -20 (50) */
/* 72 */	0x4c,		/* FC_EMBEDDED_COMPLEX */
			0x0,		/* 0 */
/* 74 */	NdrFcShort( 0xffe8 ),	/* Offset= -24 (50) */
/* 76 */	0x8,		/* FC_LONG */
			0x8,		/* FC_LONG */
/* 78 */	0x8,		/* FC_LONG */
			0x8,		/* FC_LONG */
/* 80 */	0x8,		/* FC_LONG */
			0x8,		/* FC_LONG */
/* 82 */	0x8,		/* FC_LONG */
			0x8,		/* FC_LONG */
/* 84 */	0x8,		/* FC_LONG */
			0x6,		/* FC_SHORT */
/* 86 */	0x3e,		/* FC_STRUCTPAD2 */
			0x5b,		/* FC_END */
/* 88 */	
			0x11, 0x4,	/* FC_RP [alloced_on_stack] */
/* 90 */	NdrFcShort( 0xffa8 ),	/* Offset= -88 (2) */

			0x0
        }
    };

XFG_TRAMPOLINES(BSTR)

static const USER_MARSHAL_ROUTINE_QUADRUPLE UserMarshalRoutines[ WIRE_MARSHAL_TABLE_SIZE ] = 
        {
            
            {
            (USER_MARSHAL_SIZING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserSize)
            ,(USER_MARSHAL_MARSHALLING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserMarshal)
            ,(USER_MARSHAL_UNMARSHALLING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserUnmarshal)
            ,(USER_MARSHAL_FREEING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserFree)
            
            }
            

        };



/* Standard interface: __MIDL_itf_ITerminalHandoff_0000_0000, ver. 0.0,
   GUID={0x00000000,0x0000,0x0000,{0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}} */


/* Object interface: IUnknown, ver. 0.0,
   GUID={0x00000000,0x0000,0x0000,{0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}} */


/* Object interface: ITerminalHandoff, ver. 0.0,
   GUID={0x59D55CCE,0xFC8A,0x48B4,{0xAC,0xE8,0x0A,0x92,0x86,0xC6,0x55,0x7F}} */

#pragma code_seg(".orpc")
static const unsigned short ITerminalHandoff_FormatStringOffsetTable[] =
    {
    0
    };



/* Object interface: ITerminalHandoff2, ver. 0.0,
   GUID={0xAA6B364F,0x4A50,0x4176,{0x90,0x02,0x0A,0xE7,0x55,0xE7,0xB5,0xEF}} */

#pragma code_seg(".orpc")
static const unsigned short ITerminalHandoff2_FormatStringOffsetTable[] =
    {
    68
    };



/* Object interface: ITerminalHandoff3, ver. 0.0,
   GUID={0x6F23DA90,0x15C5,0x4203,{0x9D,0xB0,0x64,0xE7,0x3F,0x1B,0x1B,0x00}} */

#pragma code_seg(".orpc")
static const unsigned short ITerminalHandoff3_FormatStringOffsetTable[] =
    {
    142
    };



#endif /* defined(_M_AMD64)*/



/* this ALWAYS GENERATED file contains the proxy stub code */


 /* File created by MIDL compiler version 8.01.0628 */
/* at Mon Jan 18 22:14:07 2038
 */
/* Compiler settings for C:\Users\amant\.t3\worktrees\winghostty\wt-issues-b2-handoff\src\apprt\win32_terminal_handoff_proxy\ITerminalHandoff.idl:
    Oicf, W1, Zp8, env=Win64 (32b run), target_arch=AMD64 8.01.0628 
    protocol : all , ms_ext, c_ext, robust
    error checks: allocation ref bounds_check enum stub_data 
    VC __declspec() decoration level: 
         __declspec(uuid()), __declspec(selectany), __declspec(novtable)
         DECLSPEC_UUID(), MIDL_INTERFACE()
*/
/* @@MIDL_FILE_HEADING(  ) */

#if defined(_M_AMD64)



extern const USER_MARSHAL_ROUTINE_QUADRUPLE NDR64_UserMarshalRoutines[ WIRE_MARSHAL_TABLE_SIZE ];extern const USER_MARSHAL_ROUTINE_QUADRUPLE UserMarshalRoutines[ WIRE_MARSHAL_TABLE_SIZE ];

#if !defined(__RPC_WIN64__)
#error  Invalid build platform for this stub.
#endif


#include "ndr64types.h"
#include "pshpack8.h"
#ifdef __cplusplus
namespace {
#endif


typedef 
NDR64_FORMAT_CHAR
__midl_frag38_t;
extern const __midl_frag38_t __midl_frag38;

typedef 
struct _NDR64_POINTER_FORMAT
__midl_frag37_t;
extern const __midl_frag37_t __midl_frag37;

typedef 
struct _NDR64_SYSTEM_HANDLE_FORMAT
__midl_frag36_t;
extern const __midl_frag36_t __midl_frag36;

typedef 
struct _NDR64_SYSTEM_HANDLE_FORMAT
__midl_frag34_t;
extern const __midl_frag34_t __midl_frag34;

typedef 
struct _NDR64_SYSTEM_HANDLE_FORMAT
__midl_frag33_t;
extern const __midl_frag33_t __midl_frag33;

typedef 
struct _NDR64_POINTER_FORMAT
__midl_frag31_t;
extern const __midl_frag31_t __midl_frag31;

typedef 
struct 
{
    struct _NDR64_PROC_FORMAT frag1;
    struct _NDR64_PARAM_FORMAT frag2;
    struct _NDR64_PARAM_FORMAT frag3;
    struct _NDR64_PARAM_FORMAT frag4;
    struct _NDR64_PARAM_FORMAT frag5;
    struct _NDR64_PARAM_FORMAT frag6;
    struct _NDR64_PARAM_FORMAT frag7;
    struct _NDR64_PARAM_FORMAT frag8;
    struct _NDR64_PARAM_FORMAT frag9;
}
__midl_frag28_t;
extern const __midl_frag28_t __midl_frag28;

typedef 
struct _NDR64_POINTER_FORMAT
__midl_frag26_t;
extern const __midl_frag26_t __midl_frag26;

typedef 
struct _NDR64_USER_MARSHAL_FORMAT
__midl_frag25_t;
extern const __midl_frag25_t __midl_frag25;

typedef 
NDR64_FORMAT_CHAR
__midl_frag24_t;
extern const __midl_frag24_t __midl_frag24;

typedef 
struct 
{
    NDR64_FORMAT_UINT32 frag1;
    struct _NDR64_EXPR_VAR frag2;
}
__midl_frag23_t;
extern const __midl_frag23_t __midl_frag23;

typedef 
struct 
{
    struct _NDR64_CONF_ARRAY_HEADER_FORMAT frag1;
    struct _NDR64_ARRAY_ELEMENT_INFO frag2;
}
__midl_frag22_t;
extern const __midl_frag22_t __midl_frag22;

typedef 
struct 
{
    struct _NDR64_CONF_STRUCTURE_HEADER_FORMAT frag1;
}
__midl_frag21_t;
extern const __midl_frag21_t __midl_frag21;

typedef 
struct 
{
    struct _NDR64_BOGUS_STRUCTURE_HEADER_FORMAT frag1;
    struct 
    {
        struct _NDR64_EMBEDDED_COMPLEX_FORMAT frag1;
        struct _NDR64_EMBEDDED_COMPLEX_FORMAT frag2;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag3;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag4;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag5;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag6;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag7;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag8;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag9;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag10;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag11;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag12;
        struct _NDR64_MEMPAD_FORMAT frag13;
        struct _NDR64_BUFFER_ALIGN_FORMAT frag14;
        struct _NDR64_SIMPLE_MEMBER_FORMAT frag15;
    } frag2;
}
__midl_frag18_t;
extern const __midl_frag18_t __midl_frag18;

typedef 
struct 
{
    struct _NDR64_PROC_FORMAT frag1;
    struct _NDR64_PARAM_FORMAT frag2;
    struct _NDR64_PARAM_FORMAT frag3;
    struct _NDR64_PARAM_FORMAT frag4;
    struct _NDR64_PARAM_FORMAT frag5;
    struct _NDR64_PARAM_FORMAT frag6;
    struct _NDR64_PARAM_FORMAT frag7;
    struct _NDR64_PARAM_FORMAT frag8;
    struct _NDR64_PARAM_FORMAT frag9;
}
__midl_frag10_t;
extern const __midl_frag10_t __midl_frag10;

typedef 
struct 
{
    struct _NDR64_PROC_FORMAT frag1;
    struct _NDR64_PARAM_FORMAT frag2;
    struct _NDR64_PARAM_FORMAT frag3;
    struct _NDR64_PARAM_FORMAT frag4;
    struct _NDR64_PARAM_FORMAT frag5;
    struct _NDR64_PARAM_FORMAT frag6;
    struct _NDR64_PARAM_FORMAT frag7;
    struct _NDR64_PARAM_FORMAT frag8;
}
__midl_frag2_t;
extern const __midl_frag2_t __midl_frag2;

typedef 
NDR64_FORMAT_UINT32
__midl_frag1_t;
extern const __midl_frag1_t __midl_frag1;

static const __midl_frag38_t __midl_frag38 =
0x5    /* FC64_INT32 */;

static const __midl_frag37_t __midl_frag37 =
{ 
/* *TERMINAL_STARTUP_INFO */
    0x20,    /* FC64_RP */
    (NDR64_UINT8) 0 /* 0x0 */,
    (NDR64_UINT16) 0 /* 0x0 */,
    &__midl_frag18
};

static const __midl_frag36_t __midl_frag36 =
{ 
/* HANDLE */
    0x3c,    /* FC64_SYSTEM_HANDLE */
    (NDR64_UINT8) 4 /* 0x4 */,
    (NDR64_UINT32) 0 /* 0x0 */,
};

static const __midl_frag34_t __midl_frag34 =
{ 
/* HANDLE */
    0x3c,    /* FC64_SYSTEM_HANDLE */
    (NDR64_UINT8) 0 /* 0x0 */,
    (NDR64_UINT32) 0 /* 0x0 */,
};

static const __midl_frag33_t __midl_frag33 =
{ 
/* HANDLE */
    0x3c,    /* FC64_SYSTEM_HANDLE */
    (NDR64_UINT8) 12 /* 0xc */,
    (NDR64_UINT32) 0 /* 0x0 */,
};

static const __midl_frag31_t __midl_frag31 =
{ 
/* *HANDLE */
    0x20,    /* FC64_RP */
    (NDR64_UINT8) 4 /* 0x4 */,
    (NDR64_UINT16) 0 /* 0x0 */,
    &__midl_frag33
};

static const __midl_frag28_t __midl_frag28 =
{ 
/* EstablishPtyHandoff */
    { 
    /* EstablishPtyHandoff */      /* procedure EstablishPtyHandoff */
        (NDR64_UINT32) 3014979 /* 0x2e0143 */,    /* auto handle */ /* IsIntrepreted, [object], ServerMustSize, ClientMustSize, HasReturn, ServerCorrelation */
        (NDR64_UINT32) 72 /* 0x48 */ ,  /* Stack size */
        (NDR64_UINT32) 0 /* 0x0 */,
        (NDR64_UINT32) 8 /* 0x8 */,
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT16) 8 /* 0x8 */,
        (NDR64_UINT16) 0 /* 0x0 */
    },
    { 
    /* in */      /* parameter in */
        &__midl_frag33,
        { 
        /* in */
            1,
            1,
            0,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            1
        },    /* MustSize, MustFree, [out], SimpleRef, UseCache */
        (NDR64_UINT16) 0 /* 0x0 */,
        8 /* 0x8 */,   /* Stack offset */
    },
    { 
    /* out */      /* parameter out */
        &__midl_frag33,
        { 
        /* out */
            1,
            1,
            0,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            1
        },    /* MustSize, MustFree, [out], SimpleRef, UseCache */
        (NDR64_UINT16) 0 /* 0x0 */,
        16 /* 0x10 */,   /* Stack offset */
    },
    { 
    /* signal */      /* parameter signal */
        &__midl_frag33,
        { 
        /* signal */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        24 /* 0x18 */,   /* Stack offset */
    },
    { 
    /* reference */      /* parameter reference */
        &__midl_frag34,
        { 
        /* reference */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        32 /* 0x20 */,   /* Stack offset */
    },
    { 
    /* server */      /* parameter server */
        &__midl_frag36,
        { 
        /* server */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        40 /* 0x28 */,   /* Stack offset */
    },
    { 
    /* client */      /* parameter client */
        &__midl_frag36,
        { 
        /* client */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        48 /* 0x30 */,   /* Stack offset */
    },
    { 
    /* startupInfo */      /* parameter startupInfo */
        &__midl_frag18,
        { 
        /* startupInfo */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], SimpleRef */
        (NDR64_UINT16) 0 /* 0x0 */,
        56 /* 0x38 */,   /* Stack offset */
    },
    { 
    /* HRESULT */      /* parameter HRESULT */
        &__midl_frag38,
        { 
        /* HRESULT */
            0,
            0,
            0,
            0,
            1,
            1,
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* [out], IsReturn, Basetype, ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        64 /* 0x40 */,   /* Stack offset */
    }
};

static const __midl_frag26_t __midl_frag26 =
{ 
/* *FLAGGED_WORD_BLOB */
    0x21,    /* FC64_UP */
    (NDR64_UINT8) 0 /* 0x0 */,
    (NDR64_UINT16) 0 /* 0x0 */,
    &__midl_frag21
};

static const __midl_frag25_t __midl_frag25 =
{ 
/* wireBSTR */
    0xa2,    /* FC64_USER_MARSHAL */
    (NDR64_UINT8) 128 /* 0x80 */,
    (NDR64_UINT16) 0 /* 0x0 */,
    (NDR64_UINT16) 7 /* 0x7 */,
    (NDR64_UINT16) 8 /* 0x8 */,
    (NDR64_UINT32) 8 /* 0x8 */,
    (NDR64_UINT32) 0 /* 0x0 */,
    &__midl_frag26
};

static const __midl_frag24_t __midl_frag24 =
0x4    /* FC64_INT16 */;

static const __midl_frag23_t __midl_frag23 =
{ 
/*  */
    (NDR64_UINT32) 1 /* 0x1 */,
    { 
    /* struct _NDR64_EXPR_VAR */
        0x3,    /* FC_EXPR_VAR */
        0x6,    /* FC64_UINT32 */
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT32) 4 /* 0x4 */
    }
};

static const __midl_frag22_t __midl_frag22 =
{ 
/*  */
    { 
    /* struct _NDR64_CONF_ARRAY_HEADER_FORMAT */
        0x41,    /* FC64_CONF_ARRAY */
        (NDR64_UINT8) 1 /* 0x1 */,
        { 
        /* struct _NDR64_CONF_ARRAY_HEADER_FORMAT */
            0,
            0,
            0,
            0,
            0,
            0,
            0,
            0
        },
        (NDR64_UINT8) 0 /* 0x0 */,
        (NDR64_UINT32) 2 /* 0x2 */,
        &__midl_frag23
    },
    { 
    /* struct _NDR64_ARRAY_ELEMENT_INFO */
        (NDR64_UINT32) 2 /* 0x2 */,
        &__midl_frag24
    }
};

static const __midl_frag21_t __midl_frag21 =
{ 
/* FLAGGED_WORD_BLOB */
    { 
    /* FLAGGED_WORD_BLOB */
        0x32,    /* FC64_CONF_STRUCT */
        (NDR64_UINT8) 3 /* 0x3 */,
        { 
        /* FLAGGED_WORD_BLOB */
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0
        },
        (NDR64_UINT8) 0 /* 0x0 */,
        (NDR64_UINT32) 8 /* 0x8 */,
        &__midl_frag22
    }
};

static const __midl_frag18_t __midl_frag18 =
{ 
/* TERMINAL_STARTUP_INFO */
    { 
    /* TERMINAL_STARTUP_INFO */
        0x34,    /* FC64_BOGUS_STRUCT */
        (NDR64_UINT8) 7 /* 0x7 */,
        { 
        /* TERMINAL_STARTUP_INFO */
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            0
        },
        (NDR64_UINT8) 0 /* 0x0 */,
        (NDR64_UINT32) 56 /* 0x38 */,
        0,
        0,
        0,
    },
    { 
    /*  */
        { 
        /* struct _NDR64_EMBEDDED_COMPLEX_FORMAT */
            0x91,    /* FC64_EMBEDDED_COMPLEX */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            &__midl_frag25
        },
        { 
        /* struct _NDR64_EMBEDDED_COMPLEX_FORMAT */
            0x91,    /* FC64_EMBEDDED_COMPLEX */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            &__midl_frag25
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x5,    /* FC64_INT32 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x4,    /* FC64_INT16 */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_MEMPAD_FORMAT */
            0x90,    /* FC64_STRUCTPADN */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 2 /* 0x2 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* TERMINAL_STARTUP_INFO */
            0x92,    /* FC64_BUFFER_ALIGN */
            (NDR64_UINT8) 7 /* 0x7 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        },
        { 
        /* struct _NDR64_SIMPLE_MEMBER_FORMAT */
            0x93,    /* FC64_END */
            (NDR64_UINT8) 0 /* 0x0 */,
            (NDR64_UINT16) 0 /* 0x0 */,
            (NDR64_UINT32) 0 /* 0x0 */
        }
    }
};

static const __midl_frag10_t __midl_frag10 =
{ 
/* EstablishPtyHandoff */
    { 
    /* EstablishPtyHandoff */      /* procedure EstablishPtyHandoff */
        (NDR64_UINT32) 36438339 /* 0x22c0143 */,    /* auto handle */ /* IsIntrepreted, [object], ClientMustSize, HasReturn, ServerCorrelation, actual guaranteed */
        (NDR64_UINT32) 72 /* 0x48 */ ,  /* Stack size */
        (NDR64_UINT32) 0 /* 0x0 */,
        (NDR64_UINT32) 8 /* 0x8 */,
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT16) 8 /* 0x8 */,
        (NDR64_UINT16) 0 /* 0x0 */
    },
    { 
    /* in */      /* parameter in */
        &__midl_frag33,
        { 
        /* in */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        8 /* 0x8 */,   /* Stack offset */
    },
    { 
    /* out */      /* parameter out */
        &__midl_frag33,
        { 
        /* out */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        16 /* 0x10 */,   /* Stack offset */
    },
    { 
    /* signal */      /* parameter signal */
        &__midl_frag33,
        { 
        /* signal */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        24 /* 0x18 */,   /* Stack offset */
    },
    { 
    /* ref */      /* parameter ref */
        &__midl_frag34,
        { 
        /* ref */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        32 /* 0x20 */,   /* Stack offset */
    },
    { 
    /* server */      /* parameter server */
        &__midl_frag36,
        { 
        /* server */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        40 /* 0x28 */,   /* Stack offset */
    },
    { 
    /* client */      /* parameter client */
        &__midl_frag36,
        { 
        /* client */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        48 /* 0x30 */,   /* Stack offset */
    },
    { 
    /* startupInfo */      /* parameter startupInfo */
        &__midl_frag18,
        { 
        /* startupInfo */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], SimpleRef */
        (NDR64_UINT16) 0 /* 0x0 */,
        56 /* 0x38 */,   /* Stack offset */
    },
    { 
    /* HRESULT */      /* parameter HRESULT */
        &__midl_frag38,
        { 
        /* HRESULT */
            0,
            0,
            0,
            0,
            1,
            1,
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* [out], IsReturn, Basetype, ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        64 /* 0x40 */,   /* Stack offset */
    }
};

static const __midl_frag2_t __midl_frag2 =
{ 
/* EstablishPtyHandoff */
    { 
    /* EstablishPtyHandoff */      /* procedure EstablishPtyHandoff */
        (NDR64_UINT32) 786755 /* 0xc0143 */,    /* auto handle */ /* IsIntrepreted, [object], ClientMustSize, HasReturn */
        (NDR64_UINT32) 64 /* 0x40 */ ,  /* Stack size */
        (NDR64_UINT32) 0 /* 0x0 */,
        (NDR64_UINT32) 8 /* 0x8 */,
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT16) 0 /* 0x0 */,
        (NDR64_UINT16) 7 /* 0x7 */,
        (NDR64_UINT16) 0 /* 0x0 */
    },
    { 
    /* in */      /* parameter in */
        &__midl_frag33,
        { 
        /* in */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        8 /* 0x8 */,   /* Stack offset */
    },
    { 
    /* out */      /* parameter out */
        &__midl_frag33,
        { 
        /* out */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        16 /* 0x10 */,   /* Stack offset */
    },
    { 
    /* signal */      /* parameter signal */
        &__midl_frag33,
        { 
        /* signal */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        24 /* 0x18 */,   /* Stack offset */
    },
    { 
    /* ref */      /* parameter ref */
        &__midl_frag34,
        { 
        /* ref */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        32 /* 0x20 */,   /* Stack offset */
    },
    { 
    /* server */      /* parameter server */
        &__midl_frag36,
        { 
        /* server */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        40 /* 0x28 */,   /* Stack offset */
    },
    { 
    /* client */      /* parameter client */
        &__midl_frag36,
        { 
        /* client */
            1,
            1,
            0,
            1,
            0,
            0,
            0,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* MustSize, MustFree, [in], ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        48 /* 0x30 */,   /* Stack offset */
    },
    { 
    /* HRESULT */      /* parameter HRESULT */
        &__midl_frag38,
        { 
        /* HRESULT */
            0,
            0,
            0,
            0,
            1,
            1,
            1,
            1,
            0,
            0,
            0,
            0,
            0,
            (NDR64_UINT16) 0 /* 0x0 */,
            0
        },    /* [out], IsReturn, Basetype, ByValue */
        (NDR64_UINT16) 0 /* 0x0 */,
        56 /* 0x38 */,   /* Stack offset */
    }
};

static const __midl_frag1_t __midl_frag1 =
(NDR64_UINT32) 0 /* 0x0 */;
#ifdef __cplusplus
}
#endif


#include "poppack.h"


XFG_TRAMPOLINES64(BSTR)

static const USER_MARSHAL_ROUTINE_QUADRUPLE NDR64_UserMarshalRoutines[ WIRE_MARSHAL_TABLE_SIZE ] = 
        {
            
            {
            (USER_MARSHAL_SIZING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserSize64)
            ,(USER_MARSHAL_MARSHALLING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserMarshal64)
            ,(USER_MARSHAL_UNMARSHALLING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserUnmarshal64)
            ,(USER_MARSHAL_FREEING_ROUTINE)XFG_TRAMPOLINE_FPTR(BSTR_UserFree64)
            
            }
            

        };



/* Standard interface: __MIDL_itf_ITerminalHandoff_0000_0000, ver. 0.0,
   GUID={0x00000000,0x0000,0x0000,{0x00,0x00,0x00,0x00,0x00,0x00,0x00,0x00}} */


/* Object interface: IUnknown, ver. 0.0,
   GUID={0x00000000,0x0000,0x0000,{0xC0,0x00,0x00,0x00,0x00,0x00,0x00,0x46}} */


/* Object interface: ITerminalHandoff, ver. 0.0,
   GUID={0x59D55CCE,0xFC8A,0x48B4,{0xAC,0xE8,0x0A,0x92,0x86,0xC6,0x55,0x7F}} */

#pragma code_seg(".orpc")
static const FormatInfoRef ITerminalHandoff_Ndr64ProcTable[] =
    {
    &__midl_frag2
    };


static const MIDL_SYNTAX_INFO ITerminalHandoff_SyntaxInfo [  2 ] = 
    {
    {
    {{0x8A885D04,0x1CEB,0x11C9,{0x9F,0xE8,0x08,0x00,0x2B,0x10,0x48,0x60}},{2,0}},
    0,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    &ITerminalHandoff_FormatStringOffsetTable[-3],
    ITerminalHandoff__MIDL_TypeFormatString.Format,
    UserMarshalRoutines,
    0,
    0
    }
    ,{
    {{0x71710533,0xbeba,0x4937,{0x83,0x19,0xb5,0xdb,0xef,0x9c,0xcc,0x36}},{1,0}},
    0,
    0 ,
    (unsigned short *) &ITerminalHandoff_Ndr64ProcTable[-3],
    0,
    NDR64_UserMarshalRoutines,
    0,
    0
    }
    };

static const MIDL_STUBLESS_PROXY_INFO ITerminalHandoff_ProxyInfo =
    {
    &Object_StubDesc,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    &ITerminalHandoff_FormatStringOffsetTable[-3],
    (RPC_SYNTAX_IDENTIFIER*)&_RpcTransferSyntax_2_0,
    2,
    (MIDL_SYNTAX_INFO*)ITerminalHandoff_SyntaxInfo
    
    };


static const MIDL_SERVER_INFO ITerminalHandoff_ServerInfo = 
    {
    &Object_StubDesc,
    0,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    (unsigned short *) &ITerminalHandoff_FormatStringOffsetTable[-3],
    0,
    (RPC_SYNTAX_IDENTIFIER*)&_NDR64_RpcTransferSyntax_1_0,
    2,
    (MIDL_SYNTAX_INFO*)ITerminalHandoff_SyntaxInfo
    };
const CINTERFACE_PROXY_VTABLE(4) _ITerminalHandoffProxyVtbl = 
{
    &ITerminalHandoff_ProxyInfo,
    &IID_ITerminalHandoff,
    IUnknown_QueryInterface_Proxy,
    IUnknown_AddRef_Proxy,
    IUnknown_Release_Proxy ,
    ObjectStublessClient3 /* ITerminalHandoff::EstablishPtyHandoff */
};

const CInterfaceStubVtbl _ITerminalHandoffStubVtbl =
{
    &IID_ITerminalHandoff,
    &ITerminalHandoff_ServerInfo,
    4,
    0, /* pure interpreted */
    CStdStubBuffer_METHODS_OPT
};


/* Object interface: ITerminalHandoff2, ver. 0.0,
   GUID={0xAA6B364F,0x4A50,0x4176,{0x90,0x02,0x0A,0xE7,0x55,0xE7,0xB5,0xEF}} */

#pragma code_seg(".orpc")
static const FormatInfoRef ITerminalHandoff2_Ndr64ProcTable[] =
    {
    &__midl_frag10
    };


static const MIDL_SYNTAX_INFO ITerminalHandoff2_SyntaxInfo [  2 ] = 
    {
    {
    {{0x8A885D04,0x1CEB,0x11C9,{0x9F,0xE8,0x08,0x00,0x2B,0x10,0x48,0x60}},{2,0}},
    0,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    &ITerminalHandoff2_FormatStringOffsetTable[-3],
    ITerminalHandoff__MIDL_TypeFormatString.Format,
    UserMarshalRoutines,
    0,
    0
    }
    ,{
    {{0x71710533,0xbeba,0x4937,{0x83,0x19,0xb5,0xdb,0xef,0x9c,0xcc,0x36}},{1,0}},
    0,
    0 ,
    (unsigned short *) &ITerminalHandoff2_Ndr64ProcTable[-3],
    0,
    NDR64_UserMarshalRoutines,
    0,
    0
    }
    };

static const MIDL_STUBLESS_PROXY_INFO ITerminalHandoff2_ProxyInfo =
    {
    &Object_StubDesc,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    &ITerminalHandoff2_FormatStringOffsetTable[-3],
    (RPC_SYNTAX_IDENTIFIER*)&_RpcTransferSyntax_2_0,
    2,
    (MIDL_SYNTAX_INFO*)ITerminalHandoff2_SyntaxInfo
    
    };


static const MIDL_SERVER_INFO ITerminalHandoff2_ServerInfo = 
    {
    &Object_StubDesc,
    0,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    (unsigned short *) &ITerminalHandoff2_FormatStringOffsetTable[-3],
    0,
    (RPC_SYNTAX_IDENTIFIER*)&_NDR64_RpcTransferSyntax_1_0,
    2,
    (MIDL_SYNTAX_INFO*)ITerminalHandoff2_SyntaxInfo
    };
const CINTERFACE_PROXY_VTABLE(4) _ITerminalHandoff2ProxyVtbl = 
{
    &ITerminalHandoff2_ProxyInfo,
    &IID_ITerminalHandoff2,
    IUnknown_QueryInterface_Proxy,
    IUnknown_AddRef_Proxy,
    IUnknown_Release_Proxy ,
    ObjectStublessClient3 /* ITerminalHandoff2::EstablishPtyHandoff */
};

const CInterfaceStubVtbl _ITerminalHandoff2StubVtbl =
{
    &IID_ITerminalHandoff2,
    &ITerminalHandoff2_ServerInfo,
    4,
    0, /* pure interpreted */
    CStdStubBuffer_METHODS_OPT
};


/* Object interface: ITerminalHandoff3, ver. 0.0,
   GUID={0x6F23DA90,0x15C5,0x4203,{0x9D,0xB0,0x64,0xE7,0x3F,0x1B,0x1B,0x00}} */

#pragma code_seg(".orpc")
static const FormatInfoRef ITerminalHandoff3_Ndr64ProcTable[] =
    {
    &__midl_frag28
    };


static const MIDL_SYNTAX_INFO ITerminalHandoff3_SyntaxInfo [  2 ] = 
    {
    {
    {{0x8A885D04,0x1CEB,0x11C9,{0x9F,0xE8,0x08,0x00,0x2B,0x10,0x48,0x60}},{2,0}},
    0,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    &ITerminalHandoff3_FormatStringOffsetTable[-3],
    ITerminalHandoff__MIDL_TypeFormatString.Format,
    UserMarshalRoutines,
    0,
    0
    }
    ,{
    {{0x71710533,0xbeba,0x4937,{0x83,0x19,0xb5,0xdb,0xef,0x9c,0xcc,0x36}},{1,0}},
    0,
    0 ,
    (unsigned short *) &ITerminalHandoff3_Ndr64ProcTable[-3],
    0,
    NDR64_UserMarshalRoutines,
    0,
    0
    }
    };

static const MIDL_STUBLESS_PROXY_INFO ITerminalHandoff3_ProxyInfo =
    {
    &Object_StubDesc,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    &ITerminalHandoff3_FormatStringOffsetTable[-3],
    (RPC_SYNTAX_IDENTIFIER*)&_RpcTransferSyntax_2_0,
    2,
    (MIDL_SYNTAX_INFO*)ITerminalHandoff3_SyntaxInfo
    
    };


static const MIDL_SERVER_INFO ITerminalHandoff3_ServerInfo = 
    {
    &Object_StubDesc,
    0,
    ITerminalHandoff__MIDL_ProcFormatString.Format,
    (unsigned short *) &ITerminalHandoff3_FormatStringOffsetTable[-3],
    0,
    (RPC_SYNTAX_IDENTIFIER*)&_NDR64_RpcTransferSyntax_1_0,
    2,
    (MIDL_SYNTAX_INFO*)ITerminalHandoff3_SyntaxInfo
    };
const CINTERFACE_PROXY_VTABLE(4) _ITerminalHandoff3ProxyVtbl = 
{
    &ITerminalHandoff3_ProxyInfo,
    &IID_ITerminalHandoff3,
    IUnknown_QueryInterface_Proxy,
    IUnknown_AddRef_Proxy,
    IUnknown_Release_Proxy ,
    ObjectStublessClient3 /* ITerminalHandoff3::EstablishPtyHandoff */
};

const CInterfaceStubVtbl _ITerminalHandoff3StubVtbl =
{
    &IID_ITerminalHandoff3,
    &ITerminalHandoff3_ServerInfo,
    4,
    0, /* pure interpreted */
    CStdStubBuffer_METHODS_OPT
};

#ifdef __cplusplus
namespace {
#endif
static const MIDL_STUB_DESC Object_StubDesc = 
    {
    0,
    NdrOleAllocate,
    NdrOleFree,
    0,
    0,
    0,
    0,
    0,
    ITerminalHandoff__MIDL_TypeFormatString.Format,
    1, /* -error bounds_check flag */
    0xa0000, /* Ndr library version */
    0,
    0x8010274, /* MIDL Version 8.1.628 */
    0,
    UserMarshalRoutines,
    0,  /* notify & notify_flag routine table */
    0x2000001, /* MIDL flag */
    0, /* cs routines */
    0,   /* proxy/server info */
    0
    };
#ifdef __cplusplus
}
#endif

const CInterfaceProxyVtbl * const _ITerminalHandoff_ProxyVtblList[] = 
{
    ( CInterfaceProxyVtbl *) &_ITerminalHandoff2ProxyVtbl,
    ( CInterfaceProxyVtbl *) &_ITerminalHandoff3ProxyVtbl,
    ( CInterfaceProxyVtbl *) &_ITerminalHandoffProxyVtbl,
    0
};

const CInterfaceStubVtbl * const _ITerminalHandoff_StubVtblList[] = 
{
    ( CInterfaceStubVtbl *) &_ITerminalHandoff2StubVtbl,
    ( CInterfaceStubVtbl *) &_ITerminalHandoff3StubVtbl,
    ( CInterfaceStubVtbl *) &_ITerminalHandoffStubVtbl,
    0
};

PCInterfaceName const _ITerminalHandoff_InterfaceNamesList[] = 
{
    "ITerminalHandoff2",
    "ITerminalHandoff3",
    "ITerminalHandoff",
    0
};


#define _ITerminalHandoff_CHECK_IID(n)	IID_GENERIC_CHECK_IID( _ITerminalHandoff, pIID, n)

int __stdcall _ITerminalHandoff_IID_Lookup( const IID * pIID, int * pIndex )
{
    IID_BS_LOOKUP_SETUP

    IID_BS_LOOKUP_INITIAL_TEST( _ITerminalHandoff, 3, 2 )
    IID_BS_LOOKUP_NEXT_TEST( _ITerminalHandoff, 1 )
    IID_BS_LOOKUP_RETURN_RESULT( _ITerminalHandoff, 3, *pIndex )
    
}

EXTERN_C const ExtendedProxyFileInfo ITerminalHandoff_ProxyFileInfo = 
{
    (PCInterfaceProxyVtblList *) & _ITerminalHandoff_ProxyVtblList,
    (PCInterfaceStubVtblList *) & _ITerminalHandoff_StubVtblList,
    (const PCInterfaceName * ) & _ITerminalHandoff_InterfaceNamesList,
    0, /* no delegation */
    & _ITerminalHandoff_IID_Lookup, 
    3,
    2,
    0, /* table of [async_uuid] interfaces */
    0, /* Filler1 */
    0, /* Filler2 */
    0  /* Filler3 */
};
#if _MSC_VER >= 1200
#pragma warning(pop)
#endif


#endif /* defined(_M_AMD64)*/

