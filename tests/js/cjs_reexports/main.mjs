import { AttributeAction, SelectorType, direct, local } from "./cjs_reexports_barrel.cjs";
import { AttributeAction as TslibAction, tslibLocal } from "./cjs_reexports_tslib.cjs";
import { AttributeAction as WholeAction, direct as WholeDirect } from "./cjs_reexports_whole.cjs";
import * as ns from "./cjs_reexports_barrel.cjs";

console.log("named", AttributeAction.Equals, SelectorType.Tag, direct, local);
console.log("tslib", TslibAction.Equals, tslibLocal);
console.log("whole", WholeAction.Equals, WholeDirect);
console.log("namespace", typeof ns.AttributeAction, typeof ns.local);
