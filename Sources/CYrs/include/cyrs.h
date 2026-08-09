#ifndef CYRS_H
#define CYRS_H

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

/* Opaque handles owned by the caller. */
typedef struct CYrsDoc CYrsDoc;
typedef struct CYrsTxn CYrsTxn;
typedef struct CYrsSubscription CYrsSubscription;
typedef struct CYrsUndoManager CYrsUndoManager;
typedef struct CYrsAwareness CYrsAwareness;

/* --- Document --- */
CYrsDoc *ydoc_new(uint64_t client_id, bool skip_gc);
uint64_t ydoc_client_id(CYrsDoc *doc);
void ydoc_destroy(CYrsDoc *doc);

/* --- Transaction (write; also used for reads). Commit via ytxn_commit.
 * Origin is fixed when the transaction is opened and cannot be retagged later. --- */
CYrsTxn *ytxn(CYrsDoc *doc);
CYrsTxn *ytxn_with_origin(CYrsDoc *doc, const uint8_t *origin, size_t origin_len);
void ytxn_commit(CYrsTxn *txn);

/* --- Text operations ---
 * The text type is resolved by name through the active transaction. Indices and
 * lengths are in UTF-16 code units. ytext_insert inherits active formatting;
 * ytext_insert_attrs selects explicit attributes, so even `{}` is semantically
 * distinct and clears inherited formatting for the inserted run. */
void ytext_insert(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, const uint8_t *s, size_t s_len);
void ytext_insert_attrs(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, const uint8_t *s, size_t s_len, const uint8_t *attrs, size_t attrs_len);
void ytext_remove(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, uint32_t len);
void ytext_format(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, uint32_t len, const uint8_t *attrs, size_t attrs_len);
uint8_t *ytext_string(CYrsTxn *txn, const uint8_t *name, size_t name_len, size_t *out_len);
uint32_t ytext_len(CYrsTxn *txn, const uint8_t *name, size_t name_len);
/* Delta as a JSON array of { "insert": <value>, "attributes"?: {..} } ops. */
uint8_t *ytext_delta(CYrsTxn *txn, const uint8_t *name, size_t name_len, size_t *out_len);

/* Text change observer: callback receives the change as a Yjs-style JSON delta array. */
typedef void (*YTextObserverCallback)(void *user_data, const uint8_t *delta_json, size_t delta_json_len);
CYrsSubscription *ytext_observe(CYrsDoc *doc, const uint8_t *name, size_t name_len, YTextObserverCallback cb, void *user_data);

/* --- Encoding & sync (v1) --- */
uint8_t *ytxn_state_as_update_v1(CYrsTxn *txn, const uint8_t *sv, size_t sv_len, size_t *out_len);
uint8_t *ytxn_state_vector_v1(CYrsTxn *txn, size_t *out_len);
/* Requires exactly one complete v1 update with no trailing bytes. False reports
 * decode, trailing-data, or apply failure. Apply failure may follow partial
 * prefix integration; discard the document after any false result. Values that
 * passed Swift structural validation can still be unrepresentable in yrs (for
 * example, JSON containing an escaped unpaired UTF-16 surrogate). */
bool ytxn_apply_update_v1(CYrsTxn *txn, const uint8_t *update, size_t len);

/* --- Doc-less update ops (merge / diff) --- */
uint8_t *ymerge_updates_v1(const uint8_t *concat, size_t concat_len, const size_t *lens, size_t count, size_t *out_len);
uint8_t *ydiff_update_v1(const uint8_t *update, size_t update_len, const uint8_t *sv, size_t sv_len, size_t *out_len);

/* --- Sticky index (relative position; yjs-compatible v1 encoding) --- */
uint8_t *ysticky_from_index(CYrsTxn *txn, const uint8_t *name, size_t name_len, uint32_t index, int8_t assoc, size_t *out_len);
int64_t ysticky_to_index(CYrsTxn *txn, const uint8_t *sticky, size_t sticky_len);

/* --- Update observers ---
 * The callback fires synchronously during commit with the v1 incremental update
 * and the committing transaction's origin (null/0 when unset). Buffers are valid
 * only for the duration of the call. Must subscribe with no live transaction. */
typedef void (*YUpdateCallback)(void *user_data, const uint8_t *origin, size_t origin_len, const uint8_t *update, size_t update_len);
CYrsSubscription *ydoc_observe_update_v1(CYrsDoc *doc, YUpdateCallback cb, void *user_data);
void ysubscription_free(CYrsSubscription *sub);

/* --- Undo manager (undo/redo open their own transaction; serialize externally) --- */
CYrsUndoManager *yundo_new(CYrsDoc *doc, const uint8_t *name, size_t name_len, uint64_t capture_timeout_ms);
void yundo_include_origin(CYrsUndoManager *mgr, const uint8_t *origin, size_t origin_len);
bool yundo_undo(CYrsUndoManager *mgr);
bool yundo_redo(CYrsUndoManager *mgr);
bool yundo_can_undo(CYrsUndoManager *mgr);
bool yundo_can_redo(CYrsUndoManager *mgr);
void yundo_stop_capturing(CYrsUndoManager *mgr);
void yundo_free(CYrsUndoManager *mgr);

/* --- Awareness (ephemeral presence; y-protocols/awareness compatible) --- */
typedef void (*YAwarenessCallback)(void *user_data, const uint64_t *added, size_t added_len, const uint64_t *updated, size_t updated_len, const uint64_t *removed, size_t removed_len);
CYrsAwareness *ysync_awareness_new(CYrsDoc *doc);
void ysync_awareness_free(CYrsAwareness *aw);
uint64_t ysync_awareness_client_id(CYrsAwareness *aw);
void ysync_set_local_state(CYrsAwareness *aw, const uint8_t *json, size_t json_len);
void ysync_clean_local_state(CYrsAwareness *aw);
void ysync_remove_state(CYrsAwareness *aw, uint64_t client_id);
uint8_t *ysync_states(CYrsAwareness *aw, size_t *out_len);
uint8_t *ysync_encode_update(CYrsAwareness *aw, size_t *out_len);
uint8_t *ysync_encode_update_clients(CYrsAwareness *aw, const uint64_t *clients, size_t clients_len, size_t *out_len);
bool ysync_apply_update(CYrsAwareness *aw, const uint8_t *update, size_t len);
CYrsSubscription *ysync_on_change(CYrsAwareness *aw, YAwarenessCallback cb, void *user_data);

/* --- Memory: release any uint8_t* buffer returned above --- */
void ybytes_free(uint8_t *ptr, size_t len);

#endif /* CYRS_H */
