-- |
-- We are given a list of non-linear real constraints and an 
-- interval domain for each variable that appears in one of the constraints. 
-- Intervals over-approximate the variable domains. The goal is to
-- contract these intervals as much as possible to improve the approximations.
--
-- For each constraint, e.g. 
--
--    x^2 * y - 3.5 + x < 0
--
-- and a variable in that constraint, e.g. `x`, we solve the expression 
-- for `x`. In general this is not possible for non-linear expressions, 
-- but we can workaround it by introducing fresh variables for each 
-- non-linear term:
--
--    h = x^2 * y        <==>   x = +/- sqrt(h/y)
--
--    h - 3.5 + x < 0    <==>   x < 3.5 - h
--
-- Now for each constraint, substitute each variable on the right-hand-side 
-- with it's interval domain and evaluate the expression with interval 
-- arithmatic. That yields new (potentially tighter) bounds for `x`.
-- Repeat with all other variables. Since that might contract the bounds
-- for variables, that `x` depends on, we can iterate and derive even 
-- tighter bounds for `x`. This method is not guaranteed to narrow the bounds
-- down to point intervals. Stop if convergence is less some threshold.

module Theory.NonLinearRealArithmatic.IntervalConstraintPropagation where

import Data.IntMap (IntMap)
import Data.Containers.ListUtils ( nubOrd )
import qualified Data.IntMap as M
import qualified Data.List as L
import Theory.NonLinearRealArithmatic.Interval (Interval)
import qualified Theory.NonLinearRealArithmatic.Interval as Interval
import Control.Arrow ( Arrow(second, first) )
import Control.Monad ( guard )
import Data.Function ( on )
import qualified Theory.NonLinearRealArithmatic.Interval as Inverval

-- | Variables are simply identified by integers. 
-- That makes it easy to introduce fresh variables by incrementing the 
-- largest used variable.
type Var = Int

-- Non-linear real arithmatic expressions may included addition, subtraction,
-- multiplication, division, exponentiation, roots.
data UnaryOp = Exp Int | Root Int

data BinaryOp = Add | Sub | Mul | Div

data Expr a = 
    Var Var
  | Const a
  | UnaryOp UnaryOp (Expr a)
  | BinaryOp BinaryOp (Expr a) (Expr a)

data Relation = LessThan | Equals | LessThanOrEquals

-- | Assuming the expression forms the left-hand-side of the relation, 
-- while the right-hand-side is always zero, e.g. 
-- 
--    x + 3*y - 10 <= 0
-- 
type Constraint a = (Relation, Expr a)

-- Expression evaluation using interval arithmatic

evalUnaryOp :: (Ord a, Num a, Bounded a, Floating a) => UnaryOp -> Interval a -> [Interval a]
evalUnaryOp symbol int = 
  case symbol of 
    Exp 2 -> [ Interval.square int ] 
    Root 2 -> Interval.squareRoot int
    -- TODO: extend to arbitrary positive exponents/roots
    Exp n -> error "Exponents >2 not supported yet"
    Root n -> error "Roots >2 not supported yet"

evalBinaryOp :: (Ord a, Num a, Bounded a, Fractional a) => BinaryOp -> Interval a -> Interval a -> [Interval a]
evalBinaryOp symbol int1 int2 = 
  case symbol of 
    Add -> [ int1 + int2 ]
    Sub -> [ int1 - int2 ]
    Mul -> [ int1 * int2 ]
    Div -> do 
      int2' <- Interval.reciprocal int2
      return (int1 * int2)

type VarDomains a = IntMap (Interval a)

domainOf :: Bounded a => Var -> VarDomains a -> Interval a
domainOf = M.findWithDefault Inverval.greatest

eval :: (Ord a, Bounded a, Floating a) => VarDomains a -> Expr a -> [Interval a]
eval var_domains expr = Interval.reduce $
  case expr of
    Var var -> [ domainOf var var_domains ]

    Const a -> [ Interval.singleton a ]

    UnaryOp op_symbol expr -> do 
      value <- eval var_domains expr
      evalUnaryOp op_symbol value

    BinaryOp op_symbol expr1 expr2 -> do
      value1 <- eval var_domains expr1
      value2 <- eval var_domains expr2
      evalBinaryOp op_symbol value1 value2

-- | List of variables paired with their positive integer exponents.
type Monomial = [(Var, Int)]

data NormalTerm a = NTerm { getCoeff :: a, getMonomial :: Monomial }

modifyCoeff :: (a -> a) -> NormalTerm a -> NormalTerm a
modifyCoeff f (NTerm coeff monomial) = NTerm (f coeff) monomial

modifyMonomial :: (Monomial -> Monomial) -> NormalTerm a -> NormalTerm a
modifyMonomial f (NTerm coeff monomial) = NTerm coeff (f monomial)

-- data NormalExpr a = NormalExpr { getCoeff :: a, getMonomial :: Monomial }

-- | Bring expression to normal form:
-- 
--      (r_1 * m_1) + (r_2 * m_2) + ... + (r_k * m_k)
-- 
-- where m_i are monomials (either 1 or a product of variables) and
-- r_i are constant coeffitions. E.g.
-- 
--      3*(x+y)^2 + 2*y + 10 + 5
--   =  3*x^2 + 6*x*y + 3*y^2 + 2*y + 15*1
-- 
-- TODO: property test "expression is equivalent to its normal form"
--
normalize :: forall a. (Ord a, Num a) => Expr a -> [NormalTerm a]
normalize = sum_coeffs . expand
  where
    -- Multiply out nested expressions and eliminate subtractions until
    -- we are left with a big sum, where each summand is composed of a 
    -- a constant coefficient and a monomial. That leaves potentially 
    -- many terms that can be summed up and combined into one term. 
    -- Do that separately with `sum_coeffs`.
    expand :: Expr a -> [NormalTerm a]
    expand expr =
      case expr of
        Var var -> [ NTerm 1 [(var, 1)] ]
        Const a -> [ NTerm a [] ]

        UnaryOp (Root _) _ -> error "Roots in user provided expressions not supported"

        UnaryOp (Exp n) (Const a) -> [ NTerm (a^n) [] ]
        UnaryOp (Exp n) (Var var) -> [ NTerm 1 [(var, n)] ]
        UnaryOp (Exp n) expr -> 
          if n < 1 then 
            error "Non-positive exponents not supported"
          else if n == 1 then
            expand expr
          else 
            expand $ BinaryOp Mul expr (UnaryOp (Exp (n-1)) expr)

        BinaryOp Add expr1 expr2 -> 
          expand expr1 <> expand expr2

        BinaryOp Sub expr1 expr2 -> 
          expand expr1 <> (modifyCoeff negate <$> expand expr2)

        BinaryOp Div _ _ -> error "Division in user provided expressions not supported"

        BinaryOp Mul expr1 expr2 -> do
          NTerm coeff1 vars1 <- expand expr1
          NTerm coeff2 vars2 <- expand expr2
          return $ NTerm (coeff1*coeff2) $ sum_exponents (vars1 <> vars2)

    -- Sum up exponents of same variables.
    sum_exponents :: Monomial -> Monomial
    sum_exponents = go . L.sort
      where
        go :: Monomial -> Monomial
        go ((var1, exp1) : (var2, exp2) : factors)
          | var1 == var2 = (var1, exp1+exp2) : go factors
          | otherwise = (var1, exp1) : go ((var2, exp2) : factors)
        go (factor : factors) = factor : go factors
        go [] = []

    -- Combine terms with same monomial, e.g. combine 3*x*y and 2*y*x to 5*x*y.
    --
    --  1.  Sort each monomial, so for example x*y is recognized as being the 
    --      same monomial as y*x. 
    --
    --  2.  Sort the terms BY the monomials, so equal monomials are next to 
    --      each other. 
    --
    --  3.  `go` over the terms and sum up equal monomials.
    --
    --  4.  Some terms now might have coefficient `0`. Filter them out.
    --
    sum_coeffs :: [NormalTerm a] -> [NormalTerm a]
    sum_coeffs = filter ((/= 0) . getCoeff) . go . L.sortBy (compare `on` getMonomial) . fmap (modifyMonomial L.sort)
      where
        go :: [NormalTerm a] -> [NormalTerm a]
        go ((NTerm coeff1 monomial1) : (NTerm coeff2 monomial2) : terms)
          | monomial1 == monomial2 = go (NTerm (coeff1+coeff2) monomial1 : terms)
          | otherwise = NTerm coeff1 monomial1 : go (NTerm coeff2 monomial2 : terms)
        go terms = terms

denormalize :: [NormalTerm a] -> Expr a
denormalize = foldr1 (BinaryOp Add) . fmap from_term
  where
    from_term :: NormalTerm a -> Expr a
    from_term (NTerm coeff monomial) = 
      foldr (BinaryOp Mul) (Const coeff) (from_var <$> monomial)

    from_var :: (Var, Int) -> Expr a
    from_var (var, n) 
      | n == 1 = Var var
      | n > 1  = UnaryOp (Exp n) (Var var)
      | otherwise = error "Non-positive exponents not supported."

isLinear :: Monomial -> Bool
isLinear [(var, 1)] = True
isLinear _ = False

-- | Collects all variables that appear in an expression.
varsIn :: Expr a -> [Var]
varsIn expr = case expr of 
  Var var -> [var]
  Const _ -> []
  UnaryOp _ sub_expr -> varsIn sub_expr
  BinaryOp _ sub_expr1 sub_expr2 ->
    nubOrd (varsIn sub_expr1 <> varsIn sub_expr2)

-- TODO
solveFor :: Expr a -> Var -> Expr a
solveFor = undefined

-- | 
preprocess :: forall a. (Ord a, Num a, Bounded a, Floating a) => VarDomains a -> [Constraint a] -> [(VarDomains a, Constraint a)]
preprocess var_domains constraints = do
  -- Identify largest used variable ID, to later generate fresh variables it.
  let max_var = maximum (maximum . varsIn . snd <$> constraints)
      fresh_vars = [max_var+1 ..]

  (rel, expr) <- constraints
  
  let terms = normalize expr
      terms_with_fresh_vars = zip terms fresh_vars
      
      g :: NormalTerm a -> Int -> NormalTerm a
      g (NTerm coeff monomial) fresh_var
        | isLinear monomial = NTerm coeff monomial
        | otherwise         = NTerm coeff [(fresh_var, 1)]
        
      terms' = uncurry g <$> terms_with_fresh_vars
      constraint' = (rel, denormalize terms')
      
      non_linear_terms_with_fresh_vars = filter (not . isLinear . getMonomial . fst) terms_with_fresh_vars

      -- | 
      -- For each newly added variable h_i, create a new constraint 
      --
      --     m_i - h_i = 0
      -- 
      -- and initialize the bounds of h_i to the interval we get when we substitute the
      -- variable bounds in m_i and evaluate the result using interval arithmetic
      -- (note: the result will always be a single interval because there is no
      -- division or square root in mi).
      h :: NormalTerm a -> Int -> (VarDomains a, Constraint a)
      h term fresh_var = (var_domain, new_constr)
        where
          new_constr = (Equals, denormalize [ term, NTerm (-1) [(fresh_var, 1)] ])
          [ int ] = eval var_domains (denormalize [term])
          var_domain = M.singleton fresh_var int
      
  (M.empty, constraint') : (uncurry h <$> non_linear_terms_with_fresh_vars)


contract :: forall a. (Ord a, Bounded a, Floating a) => VarDomains a -> [Constraint a] -> VarDomains a
contract var_domains0 = foldr go var_domains0 . preprocess
  where
    preprocess :: [Constraint a] -> [(Var, Relation, Expr a)]
    preprocess constraint = do  
      (rel, expr) <- constraint 
      var <- varsIn expr
      -- TODO: introduce new variables for non-linear terms
      return (var, rel, expr `solveFor` var)

    go :: (Var, Relation, Expr a) -> VarDomains a -> VarDomains a
    go (var, rel, expr) var_domains = 
      let int = eval var_domains expr
          -- TODO
          -- derive tighter intervals for `var`
      in  undefined

