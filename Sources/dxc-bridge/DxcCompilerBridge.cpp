// DxcCompilerBridge.cpp
//
// libSE2DxcCompiler.so - the ABI shim Space Engineers 2 loads in place of
// dxcompiler.dll on Linux.
//
// SE2 compiles its shaders through Vortice.Dxc, which P/Invokes
// DxcCreateInstance and marshals every string as the Windows 2-byte WCHAR.
// A Linux DXC build uses the platform wchar_t, which is 4 bytes. This shim
// exports the two DxcCreateInstance entry points, forwards them to the real
// libdxcompiler.so, and wraps IDxcCompiler3, IDxcResult and the caller's
// include handler so that strings are converted at that boundary:
// UTF-16 in from the caller, UTF-32 on to DXC, and back again for names and
// include sources.
//
// The backend is dlopened by SONAME ("libdxcompiler.so"), which the shim's
// DT_RUNPATH of $ORIGIN resolves to the copy staged beside it.
// SE2_DXCOMPILER_BACKEND overrides that with an explicit path.
//
// Built by Scripts/build_dxc.sh against the headers of the DXC tree it is
// shipped with; see Sources/dxc-bridge/README.md.

#include <dxc/dxcapi.h>

#include <atomic>
#include <cstdlib>
#include <cstring>
#include <dlfcn.h>
#include <new>
#include <string>
#include <utility>
#include <vector>

namespace
{
using CreateInstance = HRESULT (*)(REFCLSID, REFIID, void **);
using CreateInstance2 = HRESULT (*)(IMalloc *, REFCLSID, REFIID, void **);

constexpr GUID Compiler3Id = {0x228b4687, 0x5a6a, 0x4730, {0x90, 0x0c, 0x97, 0x02, 0xb2, 0x20, 0x3f, 0x54}};
constexpr GUID CompilerClassId = {0x73e22d93, 0xe6ce, 0x47f3, {0xb5, 0xbf, 0xf0, 0x66, 0x4f, 0x39, 0xc1, 0xb0}};
constexpr GUID BlobId = {0x8ba5fb08, 0x5195, 0x40e2, {0xac, 0x58, 0x0d, 0x98, 0x9c, 0x3a, 0x01, 0x02}};
constexpr GUID BlobEncodingId = {0x7241d424, 0x2646, 0x4191, {0x97, 0xc0, 0x98, 0xe9, 0x6e, 0x42, 0xfc, 0x68}};
constexpr GUID BlobWideId = {0xa3f84eab, 0x0faa, 0x497e, {0xa3, 0x9c, 0xee, 0x6e, 0xd6, 0x0b, 0x2d, 0x84}};
constexpr GUID IncludeHandlerId = {0x7f61fc7d, 0x950d, 0x467f, {0xb3, 0xe3, 0x3c, 0x02, 0xfb, 0x49, 0x18, 0x7c}};
constexpr GUID OperationResultId = {0xcedb484a, 0xd4e9, 0x445a, {0xb9, 0x91, 0xca, 0x21, 0xca, 0x15, 0x7d, 0xc2}};
constexpr GUID ResultId = {0x58346cda, 0xdde7, 0x4497, {0x94, 0x61, 0x6f, 0x87, 0xaf, 0x5e, 0x06, 0x59}};
constexpr GUID UnknownId = {0x00000000, 0x0000, 0x0000, {0xc0, 0x00, 0x00, 0x00, 0x00, 0x00, 0x00, 0x46}};

bool Equal(REFIID left, const GUID &right)
{
    return std::memcmp(&left, &right, sizeof(GUID)) == 0;
}

void *Backend()
{
    const char *overridePath = std::getenv("SE2_DXCOMPILER_BACKEND");
    static void *backend = dlopen(overridePath ? overridePath : "libdxcompiler.so", RTLD_NOW | RTLD_LOCAL);
    return backend;
}

std::u16string ToUtf16(const wchar_t *value)
{
    std::u16string result;
    if (!value)
        return result;

    for (; *value; ++value)
    {
        uint32_t codepoint = static_cast<uint32_t>(*value);
        if (codepoint <= 0xffff)
            result.push_back(static_cast<char16_t>(codepoint));
        else
        {
            codepoint -= 0x10000;
            result.push_back(static_cast<char16_t>(0xd800 + (codepoint >> 10)));
            result.push_back(static_cast<char16_t>(0xdc00 + (codepoint & 0x3ff)));
        }
    }
    return result;
}

std::wstring ToUtf32(const char16_t *value)
{
    std::wstring result;
    if (!value)
        return result;

    while (*value)
    {
        uint32_t codepoint = *value++;
        if (codepoint >= 0xd800 && codepoint <= 0xdbff && *value >= 0xdc00 && *value <= 0xdfff)
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (*value++ - 0xdc00);
        result.push_back(static_cast<wchar_t>(codepoint));
    }
    return result;
}

std::vector<char> ToUtf8(const char16_t *value, size_t length)
{
    std::vector<char> result;
    result.reserve(length);
    for (size_t i = 0; i < length; ++i)
    {
        uint32_t codepoint = value[i];
        if (codepoint >= 0xd800 && codepoint <= 0xdbff && i + 1 < length
                && value[i + 1] >= 0xdc00 && value[i + 1] <= 0xdfff)
            codepoint = 0x10000 + ((codepoint - 0xd800) << 10) + (value[++i] - 0xdc00);

        if (codepoint <= 0x7f)
            result.push_back(static_cast<char>(codepoint));
        else if (codepoint <= 0x7ff)
        {
            result.push_back(static_cast<char>(0xc0 | (codepoint >> 6)));
            result.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
        else if (codepoint <= 0xffff)
        {
            result.push_back(static_cast<char>(0xe0 | (codepoint >> 12)));
            result.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
            result.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
        else
        {
            result.push_back(static_cast<char>(0xf0 | (codepoint >> 18)));
            result.push_back(static_cast<char>(0x80 | ((codepoint >> 12) & 0x3f)));
            result.push_back(static_cast<char>(0x80 | ((codepoint >> 6) & 0x3f)));
            result.push_back(static_cast<char>(0x80 | (codepoint & 0x3f)));
        }
    }
    return result;
}

class Utf8Blob final : public IDxcBlobEncoding
{
public:
    explicit Utf8Blob(std::vector<char> data) : data_(std::move(data)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override
    {
        if (!object)
            return E_POINTER;
        *object = nullptr;
        if (Equal(iid, UnknownId) || Equal(iid, BlobId) || Equal(iid, BlobEncodingId))
        {
            *object = this;
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override
    {
        ULONG references = --references_;
        if (!references)
            delete this;
        return references;
    }

    LPVOID STDMETHODCALLTYPE GetBufferPointer() override { return data_.data(); }
    SIZE_T STDMETHODCALLTYPE GetBufferSize() override { return data_.size(); }
    HRESULT STDMETHODCALLTYPE GetEncoding(BOOL *known, UINT32 *codePage) override
    {
        if (!known || !codePage)
            return E_POINTER;
        *known = TRUE;
        *codePage = DXC_CP_UTF8;
        return S_OK;
    }

private:
    std::atomic<ULONG> references_{1};
    std::vector<char> data_;
};

class Utf16Blob final : public IDxcBlobWide
{
public:
    explicit Utf16Blob(std::u16string data) : data_(std::move(data)) {}

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override
    {
        if (!object)
            return E_POINTER;
        *object = nullptr;
        if (Equal(iid, UnknownId) || Equal(iid, BlobId) || Equal(iid, BlobEncodingId) || Equal(iid, BlobWideId))
        {
            *object = this;
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override
    {
        ULONG references = --references_;
        if (!references)
            delete this;
        return references;
    }

    LPVOID STDMETHODCALLTYPE GetBufferPointer() override { return data_.data(); }
    SIZE_T STDMETHODCALLTYPE GetBufferSize() override { return (data_.size() + 1) * sizeof(char16_t); }
    HRESULT STDMETHODCALLTYPE GetEncoding(BOOL *known, UINT32 *codePage) override
    {
        if (!known || !codePage)
            return E_POINTER;
        *known = TRUE;
        *codePage = DXC_CP_UTF16;
        return S_OK;
    }
    LPCWSTR STDMETHODCALLTYPE GetStringPointer() override
    {
        return reinterpret_cast<LPCWSTR>(data_.c_str());
    }
    SIZE_T STDMETHODCALLTYPE GetStringLength() override { return data_.size(); }

private:
    std::atomic<ULONG> references_{1};
    std::u16string data_;
};

class Result final : public IDxcResult
{
public:
    explicit Result(IDxcResult *inner) : inner_(inner) {}
    ~Result() { inner_->Release(); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override
    {
        if (!object)
            return E_POINTER;
        *object = nullptr;
        if (Equal(iid, UnknownId) || Equal(iid, OperationResultId) || Equal(iid, ResultId))
        {
            *object = this;
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }
    ULONG STDMETHODCALLTYPE Release() override
    {
        ULONG references = --references_;
        if (!references)
            delete this;
        return references;
    }

    HRESULT STDMETHODCALLTYPE GetStatus(HRESULT *status) override { return inner_->GetStatus(status); }
    HRESULT STDMETHODCALLTYPE GetResult(IDxcBlob **result) override { return inner_->GetResult(result); }
    HRESULT STDMETHODCALLTYPE GetErrorBuffer(IDxcBlobEncoding **errors) override
    {
        return inner_->GetErrorBuffer(errors);
    }
    BOOL STDMETHODCALLTYPE HasOutput(DXC_OUT_KIND kind) override { return inner_->HasOutput(kind); }
    HRESULT STDMETHODCALLTYPE GetOutput(DXC_OUT_KIND kind, REFIID iid, void **object,
            IDxcBlobWide **outputName) override
    {
        if (!outputName)
            return inner_->GetOutput(kind, iid, object, nullptr);

        *outputName = nullptr;
        IDxcBlobWide *nativeName = nullptr;
        HRESULT status = inner_->GetOutput(kind, iid, object, &nativeName);
        if (status >= 0 && nativeName)
        {
            try
            {
                std::u16string converted = ToUtf16(nativeName->GetStringPointer());
                auto *convertedName = new Utf16Blob(std::move(converted));
                nativeName->Release();
                *outputName = convertedName;
            }
            catch (const std::bad_alloc &)
            {
                nativeName->Release();
                if (object && *object)
                {
                    static_cast<IUnknown *>(*object)->Release();
                    *object = nullptr;
                }
                status = E_OUTOFMEMORY;
            }
        }
        return status;
    }
    UINT32 GetNumOutputs() override { return inner_->GetNumOutputs(); }
    DXC_OUT_KIND GetOutputByIndex(UINT32 index) override { return inner_->GetOutputByIndex(index); }
    DXC_OUT_KIND PrimaryOutput() override { return inner_->PrimaryOutput(); }

private:
    std::atomic<ULONG> references_{1};
    IDxcResult *inner_;
};

class IncludeHandler final : public IDxcIncludeHandler
{
public:
    explicit IncludeHandler(IDxcIncludeHandler *inner) : inner_(inner)
    {
        if (inner_)
            inner_->AddRef();
    }

    ~IncludeHandler()
    {
        if (inner_)
            inner_->Release();
    }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override
    {
        if (!object)
            return E_POINTER;
        *object = nullptr;
        if (Equal(iid, UnknownId) || Equal(iid, IncludeHandlerId))
        {
            *object = this;
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

    ULONG STDMETHODCALLTYPE Release() override
    {
        ULONG references = --references_;
        if (!references)
            delete this;
        return references;
    }

    HRESULT STDMETHODCALLTYPE LoadSource(LPCWSTR filename, IDxcBlob **source) override
    {
        std::u16string utf16 = ToUtf16(filename);
        HRESULT status = inner_->LoadSource(reinterpret_cast<LPCWSTR>(utf16.c_str()), source);
        if (status < 0 || !source || !*source)
            return status;

        IDxcBlob *utf16Source = *source;
        size_t byteLength = utf16Source->GetBufferSize();
        if (byteLength % sizeof(char16_t))
        {
            utf16Source->Release();
            *source = nullptr;
            return E_FAIL;
        }
        *source = new Utf8Blob(ToUtf8(static_cast<const char16_t *>(utf16Source->GetBufferPointer()),
            byteLength / sizeof(char16_t)));
        utf16Source->Release();
        return S_OK;
    }

private:
    std::atomic<ULONG> references_{1};
    IDxcIncludeHandler *inner_;
};

class Compiler3 final : public IDxcCompiler3
{
public:
    explicit Compiler3(IDxcCompiler3 *inner) : inner_(inner) {}
    ~Compiler3() { inner_->Release(); }

    HRESULT STDMETHODCALLTYPE QueryInterface(REFIID iid, void **object) override
    {
        if (!object)
            return E_POINTER;
        *object = nullptr;
        if (Equal(iid, UnknownId) || Equal(iid, Compiler3Id))
        {
            *object = this;
            AddRef();
            return S_OK;
        }
        return E_NOINTERFACE;
    }

    ULONG STDMETHODCALLTYPE AddRef() override { return ++references_; }

    ULONG STDMETHODCALLTYPE Release() override
    {
        ULONG references = --references_;
        if (!references)
            delete this;
        return references;
    }

    HRESULT STDMETHODCALLTYPE Compile(const DxcBuffer *source, LPCWSTR *arguments, UINT32 argumentCount,
            IDxcIncludeHandler *includeHandler, REFIID iid, void **result) override
    {
        std::vector<std::wstring> converted;
        std::vector<LPCWSTR> pointers;
        converted.reserve(argumentCount);
        pointers.reserve(argumentCount);
        for (UINT32 i = 0; i < argumentCount; ++i)
        {
            std::wstring argument = ToUtf32(reinterpret_cast<const char16_t *>(arguments[i]));
            if (argument != L"-WX")
                converted.push_back(std::move(argument));
        }
        for (const std::wstring &argument : converted)
            pointers.push_back(argument.c_str());

        DxcBuffer correctedSource = *source;
        if (correctedSource.Ptr && correctedSource.Encoding == DXC_CP_ACP)
            correctedSource.Size = std::strlen(static_cast<const char *>(correctedSource.Ptr));

        IncludeHandler *handler = includeHandler ? new IncludeHandler(includeHandler) : nullptr;
        IDxcCompiler3 *compiler = nullptr;
        void *backend = Backend();
        auto create = backend ? reinterpret_cast<CreateInstance>(dlsym(backend, "DxcCreateInstance")) : nullptr;
        HRESULT status = create
            ? create(CompilerClassId, Compiler3Id, reinterpret_cast<void **>(&compiler))
            : E_FAIL;
        if (status >= 0)
        {
            status = compiler->Compile(&correctedSource, pointers.data(), static_cast<UINT32>(pointers.size()),
                handler, iid, result);
            compiler->Release();
            if (status >= 0 && result && *result && Equal(iid, ResultId))
            {
                try
                {
                    *result = new Result(static_cast<IDxcResult *>(*result));
                }
                catch (const std::bad_alloc &)
                {
                    static_cast<IUnknown *>(*result)->Release();
                    *result = nullptr;
                    status = E_OUTOFMEMORY;
                }
            }
        }
        if (handler)
            handler->Release();
        return status;
    }

    HRESULT STDMETHODCALLTYPE Disassemble(const DxcBuffer *object, REFIID iid, void **result) override
    {
        return inner_->Disassemble(object, iid, result);
    }

private:
    std::atomic<ULONG> references_{1};
    IDxcCompiler3 *inner_;
};

HRESULT WrapCompiler(REFIID iid, void **object, HRESULT status)
{
    if (status >= 0 && object && *object && Equal(iid, Compiler3Id))
        *object = new Compiler3(static_cast<IDxcCompiler3 *>(*object));
    return status;
}
}

extern "C" __attribute__((visibility("default"))) HRESULT DxcCreateInstance(REFCLSID classId, REFIID iid, void **object)
{
    if (!object)
        return E_POINTER;
    *object = nullptr;
    void *backend = Backend();
    auto create = backend ? reinterpret_cast<CreateInstance>(dlsym(backend, "DxcCreateInstance")) : nullptr;
    try
    {
        return create ? WrapCompiler(iid, object, create(classId, iid, object)) : E_FAIL;
    }
    catch (const std::bad_alloc &)
    {
        if (*object)
            static_cast<IUnknown *>(*object)->Release();
        *object = nullptr;
        return E_OUTOFMEMORY;
    }
}

extern "C" __attribute__((visibility("default"))) HRESULT DxcCreateInstance2(
        IMalloc *allocator, REFCLSID classId, REFIID iid, void **object)
{
    if (!object)
        return E_POINTER;
    *object = nullptr;
    void *backend = Backend();
    auto create = backend ? reinterpret_cast<CreateInstance2>(dlsym(backend, "DxcCreateInstance2")) : nullptr;
    try
    {
        return create ? WrapCompiler(iid, object, create(allocator, classId, iid, object)) : E_FAIL;
    }
    catch (const std::bad_alloc &)
    {
        if (*object)
            static_cast<IUnknown *>(*object)->Release();
        *object = nullptr;
        return E_OUTOFMEMORY;
    }
}
