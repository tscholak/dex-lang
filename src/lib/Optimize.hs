-- Copyright 2020 Google LLC
--
-- Use of this source code is governed by a BSD-style
-- license that can be found in the LICENSE file or at
-- https://developers.google.com/open-source/licenses/bsd

{-# LANGUAGE FlexibleContexts #-}

module Optimize (optimizeModule, dceModule, inlineModule) where

import Control.Monad.State.Strict
import Data.Foldable
import Data.Maybe

import Syntax
import Builder
import Cat
import Subst
import Type

optimizeModule :: Module -> Module
optimizeModule = dceModule . inlineModule . narrowEffects . dceModule

-- === DCE ===

type DceM = State Scope

dceModule :: Module -> Module
dceModule (Module ir decls result) = flip evalState mempty $ do
  let EvaluatedModule bindings scs sourceMap = result
  bindings' <- traverse dceBinding bindings
  let result' = EvaluatedModule bindings' scs sourceMap
  modify (<> freeVars result')
  newDecls <- dceDecls decls
  return $ Module ir newDecls result'
  where
    dceBinding (AtomBinderInfo ty (LetBound ann expr)) =
      AtomBinderInfo ty . LetBound ann <$> dceExpr expr
    dceBinding b = return b

dceBlock :: Block -> DceM Block
dceBlock (Block decls result) = do
  newResult <- dceExpr result
  modify (<> freeVars newResult)
  newDecls <- dceDecls decls
  return $ Block newDecls newResult

dceDecls :: Nest Decl -> DceM (Nest Decl)
dceDecls decls = do
  let revDecls = reverse $ toList decls
  revNewDecls <- catMaybes <$> mapM dceDecl revDecls
  return $ toNest $ reverse $ revNewDecls

dceDecl :: Decl -> DceM (Maybe Decl)
dceDecl decl = do
  newDecl <- case decl of
    Let ann b expr -> go [b] expr $ Let ann b
  modify (<> freeVars newDecl)
  return newDecl
  where
    go bs expr mkDecl = do
      varsNeeded <- get
      forM_ bs $ modify . envDelete
      if any (`isin` varsNeeded) bs || (not $ isPure expr)
        then Just . mkDecl <$> dceExpr expr
        else return Nothing

dceExpr :: Expr -> DceM Expr
dceExpr expr = case expr of
  App g x        -> App  <$> dceAtom g <*> dceAtom x
  Atom x         -> Atom <$> dceAtom x
  Op  op         -> Op   <$> traverse dceAtom op
  Hof hof        -> Hof  <$> traverse dceAtom hof
  Case e alts ty -> Case <$> dceAtom e <*> mapM dceAlt alts <*> dceAtom ty

dceAlt :: Alt -> DceM Alt
dceAlt (Abs bs block) = Abs <$> traverse dceAbsBinder bs <*> dceBlock block

dceAbsBinder :: Binder -> DceM Binder
dceAbsBinder b = modify (envDelete b) >> return b

dceAtom :: Atom -> DceM Atom
dceAtom atom = case atom of
  Lam (Abs b (arr, block)) -> Lam <$> (Abs <$> dceAbsBinder b <*> ((arr,) <$> dceBlock block))
  _ -> return atom

-- === For inlining ===

type InlineM = SubstBuilder

inlineTraversalDef :: TraversalDef InlineM
inlineTraversalDef = (inlineTraverseDecl, inlineTraverseExpr, traverseAtom inlineTraversalDef)

inlineModule :: Module -> Module
inlineModule m = transformModuleAsBlock inlineBlock (computeInlineHints m)
  where
    inlineBlock block = fst $ runSubstBuilder mempty mempty (traverseBlock inlineTraversalDef block)

inlineTraverseDecl :: Decl -> InlineM SubstSubst
inlineTraverseDecl decl = case decl of
  Let _ b@(BindWithHint CanInline _) expr@(Hof (For _ body)) | isPure expr -> do
    ~(LamVal ib block) <- traverseAtom inlineTraversalDef body
    return $ b @> SubstVal (TabVal ib block)
  -- If `f` turns out to be an inlined table lambda, we expand its block and
  -- call ourselves recursively on the block's result expression. This makes
  -- it possible for us to e.g. discover that the result is a `for` loop, and
  -- match the case above, to continue the inlining process.
  Let letAnn letBinder (App f' x') -> do
    f <- traverseAtom inlineTraversalDef f'
    x <- traverseAtom inlineTraversalDef x'
    case f of
      TabVal b (Block body result) -> do
        dropSub $ extendR (b@>SubstVal x) $ do
          blockSubst <- traverseDeclsOpen substTraversalDef body
          extendR blockSubst $ inlineTraverseDecl $ Let letAnn letBinder result
      _ -> ((letBinder@>) . SubstVal )<$> withNameHint letBinder (emitAnn letAnn (App f x))
  _ -> traverseDecl inlineTraversalDef decl

-- TODO: This is a bit overeager. We should count under how many loops are we.
--       Even if the array is accessed in an sinkive fashion, the accesses might
--       be happen in a deeply nested loop and we might not want to repeat the
--       compute over and over.
inlineTraverseExpr :: Expr -> InlineM Expr
inlineTraverseExpr expr = case expr of
  Hof (For d body) -> do
    newBody <- traverseAtom inlineTraversalDef body
    case newBody of
      -- XXX: The trivial body might be a table lambda, and those could technically
      --      get quite expensive. But I think this should never be the case in practice.
      -- Trivial bodies
      LamVal ib block@(Block Empty (Atom _)) -> return $ Atom $ TabVal ib block
      -- Pure broadcasts
      LamVal ib@(Ignore _) block | blockEffs block == Pure -> do
        result <- dropSub $ evalBlockE inlineTraversalDef block
        Atom <$> buildLam ib TabArrow (\_ -> return $ result)
      _ -> return $ Hof $ For d newBody
  App f' x' -> do
    f <- traverseAtom inlineTraversalDef f'
    x <- traverseAtom inlineTraversalDef x'
    case f of
      TabVal b body -> Atom <$> (dropSub $ extendR (b@>SubstVal x) $ evalBlockE inlineTraversalDef body)
      _ -> return $ App f x
  _ -> nope
  where nope = traverseExpr inlineTraversalDef expr

type InlineHintM = State (Subst InlineHint)

computeInlineHints :: Module -> Module
computeInlineHints m@(Module _ _ bindings) =
    transformModuleAsBlock (flip evalState bindingsNoInline . hintBlock) m
  where
    usedInBindings = bindingsAsVars $ freeVars bindings
    bindingsNoInline = newSubst usedInBindings (repeat NoInline)

    hintBlock (Block decls result) = do
      result' <- hintExpr result  -- Traverse result before decls!
      Block <$> hintDecls decls <*> pure result'

    hintDecls decls = do
      let revDecls = reverse $ toList decls
      revNewDecls <- mapM hintDecl revDecls
      return $ toNest $ reverse $ revNewDecls

    hintDecl decl = case decl of
      Let ann b expr -> go [b] expr $ Let ann . head
      where
        go bs expr mkDecl = do
          void $ noInlineFree bs
          bs' <- traverse hintBinder bs
          forM_ bs $ modify . envDelete
          mkDecl bs' <$> hintExpr expr

    hintExpr :: Expr -> InlineHintM Expr
    hintExpr expr = case expr of
      App (Var v) x  -> App  <$> (Var v <$ use v) <*> hintAtom x
      App g x        -> App  <$> hintAtom g       <*> hintAtom x
      Atom x         -> Atom <$> hintAtom x
      Op  op         -> Op   <$> traverse hintAtom op
      Hof hof        -> Hof  <$> traverse hintAtom hof
      Case e alts ty -> Case <$> hintAtom e <*> traverse hintAlt alts <*> hintAtom ty

    hintAlt (Abs bs block) = Abs <$> traverse hintAbsBinder bs <*> hintBlock block

    hintAtom :: Atom -> InlineHintM Atom
    hintAtom atom = case atom of
      -- TODO: Is it always ok to inline e.g. into a table lambda? Even if the
      --       lambda indicates that the access pattern would be sinkive, its
      --       body can still get instantiated multiple times!
      Lam (Abs b (arr, block)) -> Lam <$> (Abs <$> hintAbsBinder b <*> ((arr,) <$> hintBlock block))
      _ -> noInlineFree atom

    use n = do
      maybeHint <- gets $ (`envLookup` n)
      let newHint = case maybeHint of
                      Nothing -> CanInline
                      Just _  -> NoInline
      modify (<> (n @> newHint))

    hintBinder :: Binder -> InlineHintM Binder
    hintBinder b = do
      maybeHint <- gets $ (`envLookup` b)
      case (b, maybeHint) of
        (Bind v  , Just hint) -> return $ BindWithHint hint   v
        (Bind v  , Nothing  ) -> return $ BindWithHint NoHint v -- TODO: Change to Ignore?
        (Ignore _, Nothing  ) -> return b
        (Ignore _, Just _   ) -> error "Ignore binder is not supposed to have any uses"

    hintAbsBinder :: Binder -> InlineHintM Binder
    hintAbsBinder b = modify (envDelete b) >> traverse hintAtom b

    noInlineFree :: HasVars a => a -> InlineHintM a
    noInlineFree a = modify (<> (fmap (const NoInline) (freeVars a))) >> return a

-- === effect narrowing ===
-- We often annotate lambdas with way more effects than they really induce
-- and this makes those annotations much more precise (but only on `for` expressions).

narrowEffects :: Module -> Module
narrowEffects m = transformModuleAsBlock narrowBlock m
  where
    narrowBlock block = fst $ runSubstBuilder mempty mempty (traverseBlock narrowingTraversalDef block)

    narrowingTraversalDef :: TraversalDef SubstBuilder
    narrowingTraversalDef = ( traverseDecl narrowingTraversalDef
                            , traverseExpr narrowingTraversalDef
                            , narrowAtom )

    narrowAtom :: Atom -> SubstBuilder Atom
    narrowAtom atom = case atom of
      Lam (Abs b (arr, body)) -> do
          b' <- mapM (traverseAtom narrowingTraversalDef) b
          ~lam@(Lam (Abs b'' (_, body''))) <-
            buildDepEffLam b'
              (\x -> extendR (b'@>SubstVal x) (substBuilderR arr))
              (\x -> extendR (b'@>SubstVal x) (evalBlockE narrowingTraversalDef body))
          return $ case arr of
            PlainArrow _ -> Lam $ Abs b'' (PlainArrow (blockEffs body''), body'')
            _            -> lam
      _ -> traverseAtom narrowingTraversalDef atom
