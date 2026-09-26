/**
 * The FieldMaps domain, named the way the database names it.
 *
 * `supabase/migrations/` is the authority: an organization owns projects, a
 * project owns sites and immutable form versions, and every observation belongs to one site and
 * one form version, carries a point in EPSG:4326 and a JSON answer object, and is revised rather
 * than edited in place. Nothing in this file invents a concept the schema does not have.
 *
 * The fixtures under `src/data/` fill these types locally. This application does not call the API
 * yet, and no screen claims otherwise.
 */

export interface Organization {
	readonly id: string;
	readonly name: string;
}

export interface Project {
	readonly id: string;
	readonly organizationId: string;
	readonly name: string;
	readonly lead: string;
	readonly leadRole: string;
	readonly summary: string;
}

/** A named sub-area of a site. Zones are the unit an observation records and a round covers. */
export interface Zone {
	readonly id: string;
	readonly label: string;
	readonly west: number;
	readonly south: number;
	readonly east: number;
	readonly north: number;
}

export type SiteState = "collecting" | "configured" | "blocked";

export interface Site {
	readonly id: string;
	readonly projectId: string;
	/** The stable short code the observer sees and the export carries. */
	readonly code: string;
	readonly name: string;
	readonly state: SiteState;
	readonly detail: string;
	readonly rounds: readonly number[];
	readonly observers: readonly string[];
	readonly zones: readonly Zone[];
}

/**
 * A published form version is immutable — the database refuses to update or delete one. Publishing
 * creates a new version alongside the old, and records keep the version they were collected under.
 */
export type FormVersionState = "published" | "draft" | "superseded";

export interface FormVersion {
	readonly id: string;
	readonly code: string;
	readonly label: string;
	readonly state: FormVersionState;
	readonly publishedAt: string | null;
	readonly recordCount: number;
	readonly variableCount: number;
	readonly note: string;
}

/** Where in the hierarchy a variable is answered. A round answer is inherited by its events. */
export type VariableScope = "event" | "round" | "zone" | "observer";

export interface Variable {
	/** The variable code in Janet's source workbook. Never invented here. */
	readonly code: string;
	/** The analysis column. Empty when the source has not supplied one. */
	readonly exportColumn: string;
	readonly label: string;
	readonly format: string;
	readonly scope: VariableScope;
	/** Whether the draft instrument currently includes it. */
	readonly included: boolean;
	/** An unresolved question about the source row. Blocks a clean publish while it stands. */
	readonly flag?: string;
}

/**
 * Display logic is authored as a when/is/show sentence, never as an expression. A manager
 * configuring a study does not write GIS expressions.
 */
export interface DisplayRule {
	readonly parent: string;
	readonly value: string;
	readonly children: string;
	/** Set when the rule as written in the workbook cannot be evaluated. */
	readonly problem?: string;
}

/** A computed check over a committed record. Nothing is auto-corrected and nothing is hidden. */
export interface QualityFlag {
	readonly id: string;
	readonly label: string;
	readonly body: string;
}

/**
 * What the database holds for a record. A record is never edited in place: a competing edit
 * raises the revision, and a withdrawal sets `deleted_at` rather than removing the row.
 */
export type RecordState = "in-database" | "revised" | "flagged" | "withdrawn";

export interface Observation {
	readonly id: string;
	readonly siteId: string;
	readonly zoneId: string;
	readonly round: number;
	readonly observerCode: string;
	/** When the observer recorded it, in the site's own time zone. */
	readonly observedAt: string;
	/** When the API committed it. Later than `observedAt` by however long the device was offline. */
	readonly receivedAt: string;
	readonly formVersionCode: string;
	readonly revision: number;
	readonly longitude: number;
	readonly latitude: number;
	readonly playType: string;
	readonly answers: readonly ObservationAnswer[];
	readonly flagId: string | null;
	readonly state: RecordState;
	readonly history: readonly ObservationEvent[];
}

export interface ObservationAnswer {
	readonly code: string;
	readonly exportColumn: string;
	readonly label: string;
	/** `null` means the display logic hid the question at collection time — not an empty answer. */
	readonly value: string | null;
}

export interface ObservationEvent {
	readonly at: string;
	readonly message: string;
}

/** A step in turning a QGIS project into something an observer can carry offline. */
export type PrepState = "done" | "warning" | "blocked" | "waiting";

export interface PrepStep {
	readonly name: string;
	readonly detail: string;
	readonly state: PrepState;
}

export interface BasemapPackage {
	readonly id: string;
	readonly siteId: string;
	readonly source: string;
	readonly detail: string;
	readonly state: PrepState;
	readonly steps: readonly PrepStep[];
}

export interface QgisLayer {
	readonly name: string;
	readonly mode: "read-only" | "view";
	readonly detail: string;
}
