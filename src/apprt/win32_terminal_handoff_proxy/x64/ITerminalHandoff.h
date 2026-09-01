

/* this ALWAYS GENERATED file contains the definitions for the interfaces */


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



/* verify that the <rpcndr.h> version is high enough to compile this file*/
#ifndef __REQUIRED_RPCNDR_H_VERSION__
#define __REQUIRED_RPCNDR_H_VERSION__ 500
#endif

#include "rpc.h"
#include "rpcndr.h"

#ifndef __RPCNDR_H_VERSION__
#error this stub requires an updated version of <rpcndr.h>
#endif /* __RPCNDR_H_VERSION__ */

#ifndef COM_NO_WINDOWS_H
#include "windows.h"
#include "ole2.h"
#endif /*COM_NO_WINDOWS_H*/

#ifndef __ITerminalHandoff_h__
#define __ITerminalHandoff_h__

#if defined(_MSC_VER) && (_MSC_VER >= 1020)
#pragma once
#endif

#ifndef DECLSPEC_XFGVIRT
#if defined(_CONTROL_FLOW_GUARD_XFG)
#define DECLSPEC_XFGVIRT(base, func) __declspec(xfg_virtual(base, func))
#else
#define DECLSPEC_XFGVIRT(base, func)
#endif
#endif

/* Forward Declarations */ 

#ifndef __ITerminalHandoff_FWD_DEFINED__
#define __ITerminalHandoff_FWD_DEFINED__
typedef interface ITerminalHandoff ITerminalHandoff;

#endif 	/* __ITerminalHandoff_FWD_DEFINED__ */


#ifndef __ITerminalHandoff2_FWD_DEFINED__
#define __ITerminalHandoff2_FWD_DEFINED__
typedef interface ITerminalHandoff2 ITerminalHandoff2;

#endif 	/* __ITerminalHandoff2_FWD_DEFINED__ */


#ifndef __ITerminalHandoff3_FWD_DEFINED__
#define __ITerminalHandoff3_FWD_DEFINED__
typedef interface ITerminalHandoff3 ITerminalHandoff3;

#endif 	/* __ITerminalHandoff3_FWD_DEFINED__ */


/* header files for imported files */
#include "unknwn.h"

#ifdef __cplusplus
extern "C"{
#endif 


/* interface __MIDL_itf_ITerminalHandoff_0000_0000 */
/* [local] */ 

typedef struct _TERMINAL_STARTUP_INFO
    {
    BSTR pszTitle;
    BSTR pszIconPath;
    LONG iconIndex;
    DWORD dwX;
    DWORD dwY;
    DWORD dwXSize;
    DWORD dwYSize;
    DWORD dwXCountChars;
    DWORD dwYCountChars;
    DWORD dwFillAttribute;
    DWORD dwFlags;
    WORD wShowWindow;
    } 	TERMINAL_STARTUP_INFO;



extern RPC_IF_HANDLE __MIDL_itf_ITerminalHandoff_0000_0000_v0_0_c_ifspec;
extern RPC_IF_HANDLE __MIDL_itf_ITerminalHandoff_0000_0000_v0_0_s_ifspec;

#ifndef __ITerminalHandoff_INTERFACE_DEFINED__
#define __ITerminalHandoff_INTERFACE_DEFINED__

/* interface ITerminalHandoff */
/* [uuid][object] */ 


EXTERN_C const IID IID_ITerminalHandoff;

#if defined(__cplusplus) && !defined(CINTERFACE)
    
    MIDL_INTERFACE("59D55CCE-FC8A-48B4-ACE8-0A9286C6557F")
    ITerminalHandoff : public IUnknown
    {
    public:
        virtual HRESULT STDMETHODCALLTYPE EstablishPtyHandoff( 
            /* [system_handle][in] */ HANDLE in,
            /* [system_handle][in] */ HANDLE out,
            /* [system_handle][in] */ HANDLE signal,
            /* [system_handle][in] */ HANDLE ref,
            /* [system_handle][in] */ HANDLE server,
            /* [system_handle][in] */ HANDLE client) = 0;
        
    };
    
    
#else 	/* C style interface */

    typedef struct ITerminalHandoffVtbl
    {
        BEGIN_INTERFACE
        
        DECLSPEC_XFGVIRT(IUnknown, QueryInterface)
        HRESULT ( STDMETHODCALLTYPE *QueryInterface )( 
            ITerminalHandoff * This,
            /* [in] */ REFIID riid,
            /* [annotation][iid_is][out] */ 
            _COM_Outptr_  void **ppvObject);
        
        DECLSPEC_XFGVIRT(IUnknown, AddRef)
        ULONG ( STDMETHODCALLTYPE *AddRef )( 
            ITerminalHandoff * This);
        
        DECLSPEC_XFGVIRT(IUnknown, Release)
        ULONG ( STDMETHODCALLTYPE *Release )( 
            ITerminalHandoff * This);
        
        DECLSPEC_XFGVIRT(ITerminalHandoff, EstablishPtyHandoff)
        HRESULT ( STDMETHODCALLTYPE *EstablishPtyHandoff )( 
            ITerminalHandoff * This,
            /* [system_handle][in] */ HANDLE in,
            /* [system_handle][in] */ HANDLE out,
            /* [system_handle][in] */ HANDLE signal,
            /* [system_handle][in] */ HANDLE ref,
            /* [system_handle][in] */ HANDLE server,
            /* [system_handle][in] */ HANDLE client);
        
        END_INTERFACE
    } ITerminalHandoffVtbl;

    interface ITerminalHandoff
    {
        CONST_VTBL struct ITerminalHandoffVtbl *lpVtbl;
    };

    

#ifdef COBJMACROS


#define ITerminalHandoff_QueryInterface(This,riid,ppvObject)	\
    ( (This)->lpVtbl -> QueryInterface(This,riid,ppvObject) ) 

#define ITerminalHandoff_AddRef(This)	\
    ( (This)->lpVtbl -> AddRef(This) ) 

#define ITerminalHandoff_Release(This)	\
    ( (This)->lpVtbl -> Release(This) ) 


#define ITerminalHandoff_EstablishPtyHandoff(This,in,out,signal,ref,server,client)	\
    ( (This)->lpVtbl -> EstablishPtyHandoff(This,in,out,signal,ref,server,client) ) 

#endif /* COBJMACROS */


#endif 	/* C style interface */




#endif 	/* __ITerminalHandoff_INTERFACE_DEFINED__ */


#ifndef __ITerminalHandoff2_INTERFACE_DEFINED__
#define __ITerminalHandoff2_INTERFACE_DEFINED__

/* interface ITerminalHandoff2 */
/* [uuid][object] */ 


EXTERN_C const IID IID_ITerminalHandoff2;

#if defined(__cplusplus) && !defined(CINTERFACE)
    
    MIDL_INTERFACE("AA6B364F-4A50-4176-9002-0AE755E7B5EF")
    ITerminalHandoff2 : public IUnknown
    {
    public:
        virtual HRESULT STDMETHODCALLTYPE EstablishPtyHandoff( 
            /* [system_handle][in] */ HANDLE in,
            /* [system_handle][in] */ HANDLE out,
            /* [system_handle][in] */ HANDLE signal,
            /* [system_handle][in] */ HANDLE ref,
            /* [system_handle][in] */ HANDLE server,
            /* [system_handle][in] */ HANDLE client,
            /* [in] */ TERMINAL_STARTUP_INFO startupInfo) = 0;
        
    };
    
    
#else 	/* C style interface */

    typedef struct ITerminalHandoff2Vtbl
    {
        BEGIN_INTERFACE
        
        DECLSPEC_XFGVIRT(IUnknown, QueryInterface)
        HRESULT ( STDMETHODCALLTYPE *QueryInterface )( 
            ITerminalHandoff2 * This,
            /* [in] */ REFIID riid,
            /* [annotation][iid_is][out] */ 
            _COM_Outptr_  void **ppvObject);
        
        DECLSPEC_XFGVIRT(IUnknown, AddRef)
        ULONG ( STDMETHODCALLTYPE *AddRef )( 
            ITerminalHandoff2 * This);
        
        DECLSPEC_XFGVIRT(IUnknown, Release)
        ULONG ( STDMETHODCALLTYPE *Release )( 
            ITerminalHandoff2 * This);
        
        DECLSPEC_XFGVIRT(ITerminalHandoff2, EstablishPtyHandoff)
        HRESULT ( STDMETHODCALLTYPE *EstablishPtyHandoff )( 
            ITerminalHandoff2 * This,
            /* [system_handle][in] */ HANDLE in,
            /* [system_handle][in] */ HANDLE out,
            /* [system_handle][in] */ HANDLE signal,
            /* [system_handle][in] */ HANDLE ref,
            /* [system_handle][in] */ HANDLE server,
            /* [system_handle][in] */ HANDLE client,
            /* [in] */ TERMINAL_STARTUP_INFO startupInfo);
        
        END_INTERFACE
    } ITerminalHandoff2Vtbl;

    interface ITerminalHandoff2
    {
        CONST_VTBL struct ITerminalHandoff2Vtbl *lpVtbl;
    };

    

#ifdef COBJMACROS


#define ITerminalHandoff2_QueryInterface(This,riid,ppvObject)	\
    ( (This)->lpVtbl -> QueryInterface(This,riid,ppvObject) ) 

#define ITerminalHandoff2_AddRef(This)	\
    ( (This)->lpVtbl -> AddRef(This) ) 

#define ITerminalHandoff2_Release(This)	\
    ( (This)->lpVtbl -> Release(This) ) 


#define ITerminalHandoff2_EstablishPtyHandoff(This,in,out,signal,ref,server,client,startupInfo)	\
    ( (This)->lpVtbl -> EstablishPtyHandoff(This,in,out,signal,ref,server,client,startupInfo) ) 

#endif /* COBJMACROS */


#endif 	/* C style interface */




#endif 	/* __ITerminalHandoff2_INTERFACE_DEFINED__ */


#ifndef __ITerminalHandoff3_INTERFACE_DEFINED__
#define __ITerminalHandoff3_INTERFACE_DEFINED__

/* interface ITerminalHandoff3 */
/* [uuid][object] */ 


EXTERN_C const IID IID_ITerminalHandoff3;

#if defined(__cplusplus) && !defined(CINTERFACE)
    
    MIDL_INTERFACE("6F23DA90-15C5-4203-9DB0-64E73F1B1B00")
    ITerminalHandoff3 : public IUnknown
    {
    public:
        virtual HRESULT STDMETHODCALLTYPE EstablishPtyHandoff( 
            /* [system_handle][out] */ HANDLE *in,
            /* [system_handle][out] */ HANDLE *out,
            /* [system_handle][in] */ HANDLE signal,
            /* [system_handle][in] */ HANDLE reference,
            /* [system_handle][in] */ HANDLE server,
            /* [system_handle][in] */ HANDLE client,
            /* [in] */ const TERMINAL_STARTUP_INFO *startupInfo) = 0;
        
    };
    
    
#else 	/* C style interface */

    typedef struct ITerminalHandoff3Vtbl
    {
        BEGIN_INTERFACE
        
        DECLSPEC_XFGVIRT(IUnknown, QueryInterface)
        HRESULT ( STDMETHODCALLTYPE *QueryInterface )( 
            ITerminalHandoff3 * This,
            /* [in] */ REFIID riid,
            /* [annotation][iid_is][out] */ 
            _COM_Outptr_  void **ppvObject);
        
        DECLSPEC_XFGVIRT(IUnknown, AddRef)
        ULONG ( STDMETHODCALLTYPE *AddRef )( 
            ITerminalHandoff3 * This);
        
        DECLSPEC_XFGVIRT(IUnknown, Release)
        ULONG ( STDMETHODCALLTYPE *Release )( 
            ITerminalHandoff3 * This);
        
        DECLSPEC_XFGVIRT(ITerminalHandoff3, EstablishPtyHandoff)
        HRESULT ( STDMETHODCALLTYPE *EstablishPtyHandoff )( 
            ITerminalHandoff3 * This,
            /* [system_handle][out] */ HANDLE *in,
            /* [system_handle][out] */ HANDLE *out,
            /* [system_handle][in] */ HANDLE signal,
            /* [system_handle][in] */ HANDLE reference,
            /* [system_handle][in] */ HANDLE server,
            /* [system_handle][in] */ HANDLE client,
            /* [in] */ const TERMINAL_STARTUP_INFO *startupInfo);
        
        END_INTERFACE
    } ITerminalHandoff3Vtbl;

    interface ITerminalHandoff3
    {
        CONST_VTBL struct ITerminalHandoff3Vtbl *lpVtbl;
    };

    

#ifdef COBJMACROS


#define ITerminalHandoff3_QueryInterface(This,riid,ppvObject)	\
    ( (This)->lpVtbl -> QueryInterface(This,riid,ppvObject) ) 

#define ITerminalHandoff3_AddRef(This)	\
    ( (This)->lpVtbl -> AddRef(This) ) 

#define ITerminalHandoff3_Release(This)	\
    ( (This)->lpVtbl -> Release(This) ) 


#define ITerminalHandoff3_EstablishPtyHandoff(This,in,out,signal,reference,server,client,startupInfo)	\
    ( (This)->lpVtbl -> EstablishPtyHandoff(This,in,out,signal,reference,server,client,startupInfo) ) 

#endif /* COBJMACROS */


#endif 	/* C style interface */




#endif 	/* __ITerminalHandoff3_INTERFACE_DEFINED__ */


/* Additional Prototypes for ALL interfaces */

unsigned long             __RPC_USER  BSTR_UserSize(     unsigned long *, unsigned long            , BSTR * ); 
unsigned char * __RPC_USER  BSTR_UserMarshal(  unsigned long *, unsigned char *, BSTR * ); 
unsigned char * __RPC_USER  BSTR_UserUnmarshal(unsigned long *, unsigned char *, BSTR * ); 
void                      __RPC_USER  BSTR_UserFree(     unsigned long *, BSTR * ); 

unsigned long             __RPC_USER  BSTR_UserSize64(     unsigned long *, unsigned long            , BSTR * ); 
unsigned char * __RPC_USER  BSTR_UserMarshal64(  unsigned long *, unsigned char *, BSTR * ); 
unsigned char * __RPC_USER  BSTR_UserUnmarshal64(unsigned long *, unsigned char *, BSTR * ); 
void                      __RPC_USER  BSTR_UserFree64(     unsigned long *, BSTR * ); 

/* end of Additional Prototypes */

#ifdef __cplusplus
}
#endif

#endif


