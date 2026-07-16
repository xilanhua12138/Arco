#ifndef ARCO_CORE_H
#define ARCO_CORE_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct ArcoRuntime ArcoRuntime;
typedef void (*ArcoEventCallback)(
    const char *name,
    const char *payload_json,
    void *context
);

ArcoRuntime *arco_runtime_create(
    const char *config_json,
    ArcoEventCallback callback,
    void *context
);
char *arco_runtime_dispatch(
    ArcoRuntime *runtime,
    const char *command,
    const char *args_json
);
void arco_runtime_destroy(ArcoRuntime *runtime);
void arco_string_free(char *value);
const char *arco_last_error_message(void);

#ifdef __cplusplus
}
#endif

#endif
