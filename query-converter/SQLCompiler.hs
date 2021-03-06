{-# LANGUAGE FlexibleContexts #-}
module SQLCompiler where

import qualified Relation as Rel
import qualified Algebra as Alg
----import qualified Natural as Nat
import qualified AbsRelAlgebra as A

import AbsMinSQL
import PrintMinSQL

import qualified Data.Map as M
import Data.List
import Control.Monad
import Control.Monad.Writer(MonadWriter(..),runWriter)
import Control.Monad.Except(MonadError(..),runExceptT)

-- based on Haskell module generated by the BNF converter

type SEnv = Alg.Env

initSEnv = Alg.initEnv

trueCond :: A.Cond
trueCond = A.CEq (A.EInt 0) (A.EInt 0) ---- trivially true condition

starIdent :: A.Ident
starIdent = A.Ident "*"  ---- aggregation over entire table

putRel :: A.Rel -> IO ()
putRel = putStrLn . Alg.prRel

type Result = String ----

failure x = error $ "Not available in algebra: " ++ printTree x
failureC c x = error $ "Cannot handle " ++ c ++ ": " ++ printTree x

throw x = throwError $ "Not available in algebra: " ++ printTree x

transId :: Ident -> Rel.Id
transId = Alg.ident2id . transIdent

transIdent :: Ident -> A.Ident
transIdent (Ident x) = A.Ident x

transStr :: Str -> String
transStr x = case x of
  Str str  -> init (tail str) -- removing '

transScript :: SEnv -> Script -> IO SEnv
transScript env x =
    put . runWriter . runExceptT $ transScript' env x
  where
    put (r,ls) = do mapM_ putStrLn ls
                    either fail return r

transScript' env x = case x of
  SStm statements  -> foldM transStatement env statements

--transStatement :: SEnv -> Statement -> IO SEnv
transStatement env x = case x of

  SCreateDatabase i -> throw x
  
  SCreateTable i typings -> do
    let ltyps = map transTyping typings
    let newtable = Rel.initTable {
         Rel.tindex  = M.fromList [(l,(i,t)) | ((l,t),i) <- zip ltyps [0..]],
         Rel.tlabels = map fst ltyps
         }
    return $ env {Alg.tables = M.insert (printTree i) newtable (Alg.tables env)}

  SDropTable i typings -> failure x

  SInsert i tableplaces_ insertvalues -> do
    let r = transId i
    case M.lookup r (Alg.tables env) of
      Just t -> do
        let t' = t {Rel.tdata = map (Alg.evalExp t []) (transInsertValues insertvalues) : Rel.tdata t}
        return $ env {Alg.tables = M.insert r t' (Alg.tables env)}
      _ -> do
        tell ["unknown table " ++ r]
        return env

  SDelete i where' -> failure x
  SUpdate i settings where' -> failure x
  SCreateView i query -> failure x
  SAlterTable i alterations -> failure x
  SCreateAssertion i condition -> failure x
  SCreateTrigger i0 triggertime1 triggeractions2 i3 triggereach4 triggerbody5 -> failure x
  
  SQuery query -> do
    let rel = transQuery query
    tell [
      "## " ++ printTree x,
      "",
      Alg.prRel rel, "",
      Rel.prTable (Alg.evalRel env rel),
----      Nat.queryRel rel,
      ""
      ]
    return env


transQuery :: Query -> A.Rel
transQuery x = case x of
  QSelect distinct columns tables where' group having order  ->
      delta $ tau $ pigamma $ sigma $ foldl1 A.RCartesian $ map transTable tables
     where
       delta = transDistinctRel distinct
       tau   = transOrder order
       sigma = transWhere where'
       
       pigamma = case (transHaving having, group, aggrs) of
         ([], GNone, [])   -> pi                         -- no aggregation
         ([], _,     _ )   -> pi               . gamma   -- no HAVING
         ([c], _,    _ )   -> pi . A.RSelect c . gamma   -- HAVING

       gamma = A.RGroup (transGroup group) aggrs

       aggrs = nub $
         [transAggrExp e | HCondition c <- [having], e <- condAggrExps c] ++      -- aggr in HAVING
         [transAggrExp e | CCExps cs <- [columns], CExp e <- cs, isAggrExp e] ++  -- aggr in SELECT
         [transAggrExp e | CCExps cs <- [columns], CExpAs e _ <- cs, isAggrExp e]

       pi = case (columns,group) of
         (CCAll,GGroupBy exps) -> A.RProject (map (A.PExp . transExp) exps)   -- SELECT * FROM gamma hides aggrs
         (CCExps cols, GGroupBy exps)
            | null [() | CExpAs _ _ <- cols] &&                         -- if no renaming takes place
              [e | CExp e <- cols, not (isAggrExp e)] == exps &&        --    all group attrs are kept
              [transAggrExp e | CExp e <- cols, isAggrExp e] == aggrs   --    all aggrs are showh
           -> id                                                        -- then no pi is needed ---- order might change
         _ -> transColumns columns       
       
       -- collecting aggregation expressions from conditions ---
       condAggrExps cond = case cond of
         COper x _ (ComExp y)  -> aggrExps x     ++ aggrExps y
         CAnd c d              -> condAggrExps c ++ condAggrExps d
         COr  c d              -> condAggrExps c ++ condAggrExps d
         CNot c                -> condAggrExps c
         _ -> error $ "not yet condExps " ++ show cond
       aggrExps exp = case exp of
         _ | isAggrExp exp -> [exp]
         _ -> [] ---- TODO: binary arithm ops
       isAggrExp exp = case exp of
         EAggr _ _ _    -> True
         EAggrAll _ _   -> True
         _ -> False 

  QSetOperation query1 setop all_ query2 -> transSetOperation setop (transQuery query1) (transQuery query2)
  QWith definitions query  -> foldr (uncurry A.RLet) (transQuery query) (map transDefinition definitions) 

transTable :: Table -> A.Rel
transTable x = case x of
  TName id      -> A.RTable (transIdent id)
  TTableAs a u  -> A.RRename (A.RRelation (transIdent u)) (transTable a)
  TQuery q u    -> A.RRename (A.RRelation (transIdent u)) (transQuery q)
  TNaturalJoin table1 jointype_ table2  -> A.RNaturalJoin (transTable table1) (transTable table2)
  TJoin table1 jointype table3 joinon  -> (case jointype of
    JTInner          -> A.RInnerJoin
    JTFull  OutOuter -> A.RFullOuterJoin
    JTLeft  OutOuter -> A.RLeftOuterJoin
    JTRight OutOuter -> A.RRightOuterJoin
    ) (transTable table1) (transJoinOn joinon) (transTable table3) 



transColumns :: Columns -> A.Rel -> A.Rel
transColumns cs rel = case cs of
  CCAll          -> rel       -- select *
  CCExps columns -> A.RProject (map transColumn columns) rel

transColumn :: Column -> A.Projection
transColumn x = case x of
  CExp exp       -> A.PExp (transExp exp)
  CExpAs exp id  -> A.PRename (transExp exp) (transIdent id)

transWhere :: Where -> A.Rel -> A.Rel
transWhere wh rel = case wh of
  WNone -> rel
  WCondition cond -> A.RSelect (transCondition cond) rel

transCondition :: Condition -> A.Cond
transCondition x = case x of
  COper exp1 oper compared  -> transCompared compared (transOper oper (transExp exp1))
  CNot c  -> A.CNot (transCondition c)
  CExists not table  -> failureC "subquery in a condition" x
  CIsNull exp not -> transNot not $ A.CEq (transExp exp) (A.EIdent (A.Ident "NULL"))
  CBetween exp1 not2 exp2 exp3  -> transNot not2 $ A.CAnd (A.CLeq (transExp exp2) (transExp exp1)) (A.CLeq (transExp exp1) (transExp exp3))
  CIn exp not2 values -> transNot not2 $ foldl1 A.COr [A.CEq (transExp exp) te | te <- transValues values] 
  CAnd c1 c2  -> A.CAnd (transCondition c1) (transCondition c2)
  COr c1 c2  -> A.COr (transCondition c1) (transCondition c2)

transNot :: Not -> A.Cond -> A.Cond
transNot x = case x of
  NNot  -> A.CNot
  NNone  -> id

transCompared :: Compared -> (A.Exp -> A.Cond) -> A.Cond
transCompared x op = case x of
  ComExp exp  -> op (transExp exp)
  ComAny values  -> foldl1 A.COr  [op te | te <- transValues values] 
  ComAll values  -> foldl1 A.CAnd [op te | te <- transValues values] 

transExp :: Exp -> A.Exp
transExp x = case x of
  EName i        -> A.EIdent (transIdent i) 
  EQual q i      -> A.EQIdent (transIdent q) (transIdent i)
  EInt n         -> A.EInt n
  EFloat n       -> A.EFloat n
  EStr s         -> A.EString (transStr s)
  EString str    -> A.EString str
  ENull          -> A.EIdent (A.Ident "NULL")
  EDefault       -> A.EIdent (A.Ident "DEFAULT")
  EQuery query   -> failureC "subquery as expression" x
  EAggr op dist arg -> Alg.projectionExp $ A.EAggr (transAggrOper op) (transDistinct dist) (exp2Ident arg)  -- refer to column in groups
  EAggrAll op dist   -> Alg.projectionExp $ A.EAggr (transAggrOper op)  (transDistinct dist) starIdent
  EMul exp1 exp2  -> A.EMul (transExp exp1) (transExp exp2)
  EDiv exp1 exp2  -> A.EDiv (transExp exp1) (transExp exp2)
  ERem exp1 exp2  -> A.ERem (transExp exp1) (transExp exp2)
  EAdd exp1 exp2  -> A.EAdd (transExp exp1) (transExp exp2)
  ESub exp1 exp2  -> A.ESub (transExp exp1) (transExp exp2)

exp2Ident :: Exp -> A.Ident
exp2Ident e = case e of 
  EName i -> transIdent i
  EQual q i -> transIdent i ----
  _ -> A.Ident "?column?" ; --- as in PostgreSQL

transSetOperation :: SetOperation -> A.Rel -> A.Rel -> A.Rel
transSetOperation x = case x of
  SOUnion  -> A.RUnion
  SOIntersect  -> A.RIntersect
  SOExcept  -> A.RExcept

transAll :: All -> Result
transAll x = case x of
  ANone  -> failure x
  AAll  -> failure x


transJoinOn :: JoinOn -> A.JoinOn
transJoinOn x = case x of
  JOCondition condition  -> A.JOCond (transCondition condition) ;
  JOUsing ids  -> A.JOIdents (map transIdent ids)


transJoinType :: JoinType -> Result
transJoinType x = case x of
  JTLeft outer  -> failure x
  JTRight outer  -> failure x
  JTFull outer  -> failure x
  JTInner  -> failure x


transOuter :: Outer -> Result
transOuter x = case x of
  OutOuter  -> failure x
  OutNone  -> failure x


transDistinct :: Distinct -> A.Distinct
transDistinct x = case x of
  DNone     -> A.DNone
  DDistinct -> A.DDistinct

transDistinctRel :: Distinct -> A.Rel -> A.Rel
transDistinctRel x rel = case x of
  DNone     -> rel
  DDistinct -> A.RDistinct rel

transGroup :: Group -> [A.Ident]
transGroup x = case x of
  GNone  -> []
  GGroupBy exps -> map exp2Ident exps

transHaving :: Having -> [A.Cond]
transHaving x = case x of
  HNone  -> []
  HCondition condition  -> [transCondition condition]

transOrder :: Order -> A.Rel -> A.Rel
transOrder x rel = case x of
  ONone  -> rel
  OOrderBy attributeorders  -> A.RSort (map transAttributeOrder attributeorders) rel

transAttributeOrder :: AttributeOrder -> A.SortExp
transAttributeOrder x = case x of
  AOAsc exp  -> A.SEAsc (transExp exp)
  AODesc exp -> A.SEDesc (transExp exp)

transSetting :: Setting -> Result
transSetting x = case x of
  SVal id exp  -> failure x

transAggrOper :: AggrOper -> A.Function
transAggrOper op = case op of
  AOAvg   -> A.FAvg
  AOMax   -> A.FMax
  AOMin   -> A.FMin
  AOSum   -> A.FSum
  AOCount -> A.FCount

---- very suspect, to revise
transAggrExp :: Exp -> A.Aggregation
transAggrExp exp = case exp of
  EAggr op dist arg  -> A.AApp (transAggrOper op) (transDistinct dist) (exp2Ident arg) 
  EAggrAll op dist   -> A.AApp (transAggrOper op) (transDistinct dist) starIdent 
  _ -> error $ "not aggregation expression " ++ show exp
  
transOper :: Oper -> A.Exp -> A.Exp -> A.Cond
transOper x = case x of
  OEq  -> A.CEq
  ONeq -> A.CNEq
  OGt  -> A.CGt
  OLt  -> A.CLt
  OGeq -> A.CGeq
  OLeq -> A.CLeq
  OLike not -> \x y -> transNot not (A.CLike x y)

transTyping :: Typing -> (Rel.Id, Rel.Type)
transTyping x = case x of
  TColumn id type' inlineconstraints_ -> (Alg.ident2id (transIdent id), transType type')
  TConstraint constraint  -> failure x
  TNamedConstraint id constraint  -> failure x

transInlineConstraint :: InlineConstraint -> Result
transInlineConstraint x = case x of
  ICPrimaryKey  -> failure x
  ICReferences id1 id2 policys3  -> failure x
  ICUnique  -> failure x
  ICNotNull  -> failure x
  ICCheck condition  -> failure x
  ICDefault value  -> failure x


transConstraint :: Constraint -> Result
transConstraint x = case x of
  CPrimaryKey ids  -> failure x
  CReferences ids1 id2 ids3 policys4  -> failure x
  CUnique ids  -> failure x
  CNotNull  -> failure x
  CCheck condition  -> failure x

transType :: Type -> Rel.Type
transType x = case x of
  TIdent (Ident "int") -> Rel.TInt  -- not reserved, hence lowercase 
  TIdent (Ident "float") -> Rel.TFloat 
  TIdent _ -> Rel.TString ----
  TSized id n  -> transType (TIdent id) ----

transPolicy :: Policy -> Result
transPolicy x = case x of
  PDelete action  -> failure x
  PUpdate action  -> failure x


transAction :: Action -> Result
transAction x = case x of
  ACascade  -> failure x
  ASetNull  -> failure x


transTablePlaces :: TablePlaces -> [A.Ident]
transTablePlaces x = case x of
  TPNone  -> failure x
  TPAttributes ids  -> map transIdent ids


transValues :: Values -> [A.Exp]
transValues x = case x of
  VValues exps  -> map transExp exps
  VQuery query  -> failure x


transInsertValues :: InsertValues -> [A.Exp]
transInsertValues x = case x of
  IVValues exps  -> map transExp exps
  IVQuery query  -> failure x

transDefinition :: Definition -> (A.Ident, A.Rel)
transDefinition x = case x of
  DTable id query  -> (transIdent id, transQuery query)

transAlteration :: Alteration -> Result
transAlteration x = case x of
  AAdd typing  -> failure x
  ADrop id  -> failure x
  AAlter id type'  -> failure x
  ADropPrimaryKey  -> failure x
  ADropConstraint id  -> failure x


transTriggerTime :: TriggerTime -> Result
transTriggerTime x = case x of
  TTBefore  -> failure x
  TTAfter  -> failure x
  TTInstead  -> failure x


transTriggerAction :: TriggerAction -> Result
transTriggerAction x = case x of
  TAUpdate  -> failure x
  TAInsert  -> failure x
  TADelete  -> failure x


transTriggerEach :: TriggerEach -> Result
transTriggerEach x = case x of
  TERow  -> failure x
  TEStatement  -> failure x


transTriggerBody :: TriggerBody -> Result
transTriggerBody x = case x of
  TBStatements triggerstatements  -> failure x
  TBProcedure id  -> failure x


transTriggerStatement :: TriggerStatement -> Result
transTriggerStatement x = case x of
  TSStatement statement  -> failure x
  TSIfThen condition triggerstatements triggerelses  -> failure x
  TSException str  -> failure x


transTriggerElse :: TriggerElse -> Result
transTriggerElse x = case x of
  TEElseIf condition triggerstatements  -> failure x



