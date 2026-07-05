#ifndef CYRS_H
#define CYRS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Opaque handles owned by the caller. */
typedef struct CYrsDoc CYrsDoc;
typedef struct CYrsTxn CYrsTxn;
typedef struct CYrsSubscription CYrsSubscription;

/* --- Document --- */
CYrsDoc *ydoc_new(uint64_t client_id, bool skip_gc);
uint64_t ydoc_client_id(CYrsDoc *doc);
void ydoc_destroy(CYrsDoc *doc);

/* --- Transaction (write; also used for reads). Commit via ytxn_commit. --- */
CYrsTxn *ytxn(CYrsDoc *doc);
CYrsTxn *ytxn_with_origin(CYrsDoc *doc, const uint8_t *origin, size_t origin_len);
void ytxn_commit(CYrsTxn *txn);

/* --- Text operations ---
 * The text type is resolved by name through the active transaction. Indices and
 * lengths are in UTF-16 code units. */
void ytext_insert(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, const uint8_t *s, size_t s_len);
void ytext_insert_attrs(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, const uint8_t *s, size_t s_len, const uint8_t *attrs, size_t attrs_len);
void ytext_remove(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, uint32_t len);
void ytext_format(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, uint32_t len, const uint8_t *attrs, size_t attrs_len);
uint8_t *ytext_string(CYrsTxn *txn, const uint8_t *name, size_t name_len, size_t *out_len);
uint32_t ytext_len(CYrsTxn *txn, const uint8_t *name, size_t name_len);
/* Delta as a JSON array of { "insert": <value>, "attributes"?: {..} } ops. */
uint8_t *ytext_delta(CYrsTxn *txn, const uint8_t *name, size_t name_len, size_t *out_len);

/* --- Encoding & sync (v1) --- */
uint8_t *ytxn_state_as_update_v1(CYrsTxn *txn, const uint8_t *sv, size_t sv_len, size_t *out_len);
uint8_t *ytxn_state_vector_v1(CYrsTxn *txn, size_t *out_len);
bool ytxn_apply_update_v1(CYrsTxn *txn, const uint8_t *update, size_t len);

/* --- Update observers ---
 * The callback fires synchronously during commit with the v1 incremental update
 * and the committing transaction's origin (null/0 when unset). Buffers are valid
 * only for the duration of the call. Must subscribe with no live transaction. */
typedef void (*YUpdateCallback)(void *user_data, const uint8_t *origin, size_t origin_len, const uint8_t *update, size_t update_len);
CYrsSubscription *ydoc_observe_update_v1(CYrsDoc *doc, YUpdateCallback cb, void *user_data);
void ysubscription_free(CYrsSubscription *sub);

/* --- Memory: release any uint8_t* buffer returned above --- */
void ybytes_free(uint8_t *ptr, size_t len);

#endif /* CYRS_H */
